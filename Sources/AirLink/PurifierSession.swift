import CoAPCore
import Foundation
import PhilipsCrypto
import PurifierModel

/// One logical connection to a purifier: sync handshake, status reads, observation and
/// control. The actor owns the protocol counter, so encrypts are serialised and the
/// counter can't race.
///
/// Every network operation has a deadline. Failures that a fresh counter might fix
/// (timeouts, digest mismatches, a refused command) get exactly one resync and one retry,
/// then surface as a `PurifierError` with advice for the user.
public actor PurifierSession {
    public enum Path {
        public static let sync = "/sys/dev/sync"
        public static let status = "/sys/dev/status"
        public static let control = "/sys/dev/control"
    }

    public let configuration: SessionConfiguration
    public private(set) var phase: SessionPhase = .idle
    /// The client counter from the last sync, advanced once per encrypted send.
    public private(set) var counter: PhilipsCounter?
    /// Learned from the first status read. Writes are refused until this is known.
    public private(set) var generation: KeyGeneration?
    /// Max-Age of the last status response (seconds); feeds the M2 observe watchdog.
    public private(set) var lastMaxAge: UInt32?
    public private(set) var quirks = DeviceQuirks()

    private let logger: WireLogger?
    private let channelFactory: ChannelFactory
    private var transport: CoAPTransport?
    private var connecting: Task<CoAPTransport, any Error>?

    public init(
        configuration: SessionConfiguration,
        logger: WireLogger? = nil,
        channelFactory: ChannelFactory? = nil
    ) {
        self.configuration = configuration
        self.logger = logger
        self.channelFactory = channelFactory ?? { host, port, timeout in
            try await UDPChannel.connect(host: host, port: port, timeout: timeout)
        }
    }

    // MARK: - Sync

    /// `POST /sys/dev/sync` with 8 random uppercase hex characters. The reply is the
    /// counter to use for the next encrypted send.
    @discardableResult
    public func sync() async throws(PurifierError) -> PhilipsCounter {
        phase = .syncing
        let transport = try await connectedTransport()
        let nonce = Self.randomHex(byteCount: 4)
        var request = CoAPMessage(
            type: configuration.messageType,
            code: .post,
            messageID: 0,
            payload: Array(nonce.utf8)
        )
        request.setURIPath(Path.sync)

        let response = try await perform("sync", timeout: configuration.syncTimeout) {
            try await transport.request(request, timeout: self.configuration.syncTimeout)
        }
        guard response.code.isSuccess else {
            throw .unexpectedResponse(operation: "sync", code: response.code, body: Self.printable(response.payload))
        }
        let text = String(decoding: response.payload, as: UTF8.self)
        guard let synced = try? PhilipsCounter(hex: text),
              configuration.counterPolicy == .unpadded || text.utf8.count == LegacyPhilipsCipher.counterLength
        else {
            throw .invalidSyncResponse(Self.printable(response.payload))
        }
        counter = synced
        phase = .ready
        logger?(.note("synced: counter \(synced.hex)"))
        return synced
    }

    /// Forgets the counter, optionally opens a fresh socket, and syncs again.
    public func resync() async throws(PurifierError) {
        logger?(.note("resyncing"))
        counter = nil
        if configuration.freshConnectionOnResync {
            await dropTransport()
        }
        try await sync()
    }

    // MARK: - Status

    /// Reads the current status once: registers an observation, takes the first
    /// notification, then cancels it. Returns `state.reported`.
    public func status() async throws(PurifierError) -> [String: JSONValue] {
        try await statusSnapshot().reported
    }

    /// A status read plus the decrypted document exactly as the device sent it.
    public struct StatusSnapshot: Sendable {
        public let reported: [String: JSONValue]
        /// The decrypted JSON text (`{"state": {"reported": …}}`), for `--raw` output.
        public let document: String
    }

    public func statusSnapshot() async throws(PurifierError) -> StatusSnapshot {
        try await withResyncRetry("status") {
            try await self.statusOnce()
        }
    }

    /// `status()`, parsed into a typed `PurifierState`.
    public func state() async throws(PurifierError) -> PurifierState {
        let reported = try await status()
        do {
            return try PurifierState(reported: reported)
        } catch {
            throw .model(error)
        }
    }

    private func statusOnce() async throws(PurifierError) -> StatusSnapshot {
        if counter == nil {
            try await sync() // aioairctrl always syncs before talking to the device
        }
        let transport = try await connectedTransport()
        var request = CoAPMessage(type: configuration.messageType, code: .get, messageID: 0)
        request.setURIPath(Path.status)
        request.observe = 0

        let observation: CoAPTransport.Observation
        do {
            observation = try await transport.observe(request)
        } catch {
            throw mapError(error, operation: "status")
        }
        let first: CoAPMessage
        do {
            first = try await perform("status", timeout: configuration.statusTimeout) {
                try await Self.withDeadline(self.configuration.statusTimeout) {
                    for try await message in observation.messages {
                        return message
                    }
                    throw PurifierError.observationEnded
                }
            }
        } catch {
            await transport.cancelObservation(token: observation.token)
            throw error
        }
        await transport.cancelObservation(token: observation.token)

        guard first.code.isSuccess else {
            throw .unexpectedResponse(operation: "status", code: first.code, body: Self.printable(first.payload))
        }
        lastMaxAge = first.maxAge ?? 60
        return try decryptStatus(first.payload)
    }

    private func decryptStatus(_ payload: [UInt8]) throws(PurifierError) -> StatusSnapshot {
        let opened: LegacyPhilipsCipher.Opened
        do {
            opened = try LegacyPhilipsCipher.open(String(decoding: payload, as: UTF8.self))
        } catch {
            throw .crypto(operation: "status", error)
        }
        let document = opened.text ?? "<\(opened.plaintext.count) bytes, not UTF-8>"
        logger?(.decrypted(direction: .incoming, json: document))
        let reported: [String: JSONValue]
        do {
            reported = try StatusDocument.reported(from: opened.plaintext)
        } catch {
            throw .model(error)
        }
        if let detected = KeyGeneration.detect(in: reported) {
            generation = detected
        }
        return StatusSnapshot(reported: reported, document: document)
    }

    // MARK: - Observe

    /// A stream of `state.reported` updates.
    ///
    /// M1: one registration, decrypted notifications passed through; frames that fail to
    /// decrypt are skipped (and logged). The stream ends when the device stops observing.
    ///
    /// TODO(M2): resync and re-register on silence (`ObserveWatchdog`), on decrypt failures,
    /// and on network changes; detect push-only firmware (`DeviceQuirks.pushOnly`).
    public func observe() -> AsyncThrowingStream<[String: JSONValue], any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [String: JSONValue].self)
        let task = Task {
            do throws(PurifierError) {
                try await self.runObservation(into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runObservation(
        into continuation: AsyncThrowingStream<[String: JSONValue], any Error>.Continuation
    ) async throws(PurifierError) {
        if counter == nil {
            try await sync()
        }
        let transport = try await connectedTransport()
        var request = CoAPMessage(type: configuration.messageType, code: .get, messageID: 0)
        request.setURIPath(Path.status)
        request.observe = 0
        let observation: CoAPTransport.Observation
        do {
            observation = try await transport.observe(request)
        } catch {
            throw mapError(error, operation: "observe")
        }
        phase = .observing
        defer { phase = .ready }
        do {
            for try await message in observation.messages {
                guard message.code.isSuccess else {
                    throw PurifierError.unexpectedResponse(
                        operation: "observe", code: message.code, body: Self.printable(message.payload)
                    )
                }
                lastMaxAge = message.maxAge ?? lastMaxAge
                do {
                    try continuation.yield(decryptStatus(message.payload).reported)
                } catch {
                    logger?(.note("skipped notification: \(error.localizedDescription)"))
                }
            }
        } catch {
            await transport.cancelObservation(token: observation.token)
            if Task.isCancelled {
                return
            }
            throw mapError(error, operation: "observe")
        }
    }

    // MARK: - Control

    /// Sends a command. Reads status first if the key generation isn't known yet, so a
    /// write never goes out in the wrong key scheme.
    public func send(_ command: Command) async throws(PurifierError) {
        if generation == nil {
            _ = try await status()
        }
        guard let generation else {
            throw .model(.unknownGeneration(sampleKeys: []))
        }
        let values: [DesiredValue]
        do {
            values = try command.desiredValues(for: generation, allowUnverified: configuration.allowUnverifiedWrites)
        } catch {
            throw .command(error)
        }
        let json = ControlRequest.json(values)
        try await withResyncRetry("control") {
            try await self.controlOnce(json)
        }
    }

    private func controlOnce(_ json: String) async throws(PurifierError) {
        if counter == nil {
            try await sync()
        }
        // Advance and encrypt with no suspension in between: no other call can reuse the counter.
        let frame: String
        do {
            guard var next = counter else { throw PurifierError.invalidSyncResponse("no counter") }
            let used = try next.advance(policy: configuration.counterPolicy)
            counter = next
            frame = try LegacyPhilipsCipher.seal(json, counter: used)
        } catch let error as PhilipsCryptoError {
            throw .crypto(operation: "control", error)
        } catch {
            throw mapError(error, operation: "control")
        }
        logger?(.decrypted(direction: .outgoing, json: json))

        let transport = try await connectedTransport()
        var request = CoAPMessage(
            type: configuration.messageType,
            code: .post,
            messageID: 0,
            payload: Array(frame.utf8)
        )
        request.setURIPath(Path.control)
        let response = try await perform("control", timeout: configuration.controlTimeout) {
            try await transport.request(request, timeout: self.configuration.controlTimeout)
        }
        logger?(.note("control reply (plain text): \(Self.printable(response.payload))"))
        guard response.code.isSuccess else {
            throw .unexpectedResponse(operation: "control", code: response.code, body: Self.printable(response.payload))
        }
        guard ControlRequest.isSuccess(response.payload) else {
            throw .controlRejected(response: Self.printable(response.payload))
        }
    }

    // MARK: - Lifecycle

    public func close() async {
        await dropTransport()
        phase = .closed
    }

    private func connectedTransport() async throws(PurifierError) -> CoAPTransport {
        if let transport {
            return transport
        }
        if let connecting {
            do {
                return try await connecting.value
            } catch {
                throw mapError(error, operation: "connect")
            }
        }
        let configuration = configuration
        let factory = channelFactory
        let logger = logger
        let task = Task { () throws -> CoAPTransport in
            let channel = try await factory(configuration.host, configuration.port, configuration.connectTimeout)
            return CoAPTransport(channel: channel, configuration: configuration.transport, logger: logger)
        }
        connecting = task
        defer { connecting = nil }
        do {
            let transport = try await task.value
            self.transport = transport
            return transport
        } catch {
            throw mapError(error, operation: "connect")
        }
    }

    private func dropTransport() async {
        connecting?.cancel()
        connecting = nil
        if let transport {
            self.transport = nil
            await transport.close()
        }
    }

    // MARK: - Helpers

    /// Runs `operation` once; if it fails in a way a fresh counter might fix, resyncs and
    /// runs it exactly once more.
    private func withResyncRetry<T: Sendable>(
        _ operation: String,
        _ body: () async throws -> T
    ) async throws(PurifierError) -> T {
        do {
            return try await body()
        } catch {
            let failure = mapError(error, operation: operation)
            guard failure.isRetryable else { throw failure }
            logger?(.note("\(operation) failed (\(failure.localizedDescription)) — resyncing and retrying once"))
            phase = .degraded(reason: "\(operation): \(failure)")
            try await resync()
            do {
                return try await body()
            } catch {
                throw mapError(error, operation: operation)
            }
        }
    }

    /// Runs a transport call and maps its errors into `PurifierError`.
    private func perform<T: Sendable>(
        _ operation: String,
        timeout: Duration,
        _ body: () async throws -> T
    ) async throws(PurifierError) -> T {
        do {
            return try await body()
        } catch {
            throw mapError(error, operation: operation, timeout: timeout)
        }
    }

    private func mapError(_ error: any Error, operation: String, timeout: Duration? = nil) -> PurifierError {
        switch error {
        case let error as PurifierError:
            error
        case let error as TransportError:
            switch error {
            case .timeout:
                .timeout(
                    operation: operation, host: configuration.endpointDescription, after: timeout ?? .zero
                )
            case .connectionRefused:
                .connectionRefused(host: configuration.endpointDescription)
            case let .unreachable(detail), let .invalidEndpoint(detail):
                .unreachable(host: configuration.endpointDescription, detail: detail)
            case .reset:
                .reset(operation: operation)
            case .closed:
                .closed
            default:
                .transport(error.description)
            }
        case is DeadlineExceeded:
            .timeout(operation: operation, host: configuration.endpointDescription, after: timeout ?? .zero)
        case is CancellationError:
            .closed
        default:
            .transport(String(describing: error))
        }
    }

    struct DeadlineExceeded: Error {}

    /// Races `operation` against a timer.
    static func withDeadline<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw DeadlineExceeded() }
            return result
        }
    }

    static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Hex.encode((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Payload text for error messages, truncated and with control characters removed.
    static func printable(_ payload: [UInt8]) -> String {
        let text = String(decoding: payload.prefix(200), as: UTF8.self)
        let cleaned = String(text.unicodeScalars
            .map { $0.properties.generalCategory == .control ? "·" : Character($0) })
        return payload.count > 200 ? cleaned + "…" : cleaned
    }
}
