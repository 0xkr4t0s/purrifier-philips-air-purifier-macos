import CoAPCore
import Foundation
import Network
import PhilipsCrypto
import PurifierModel

/// A simulated Philips Air+ purifier: the device side of sync, status (with Observe) and
/// control, using the same frame format and crypto as the real thing, over real UDP.
///
/// Behaviour that real firmware may or may not share is marked as an assumption. The
/// simulator exists to test the client's state machine and fault handling, not to
/// document the device.
public actor FakePurifier {
    /// Static behaviour.
    public struct Behavior: Sendable {
        /// The counter returned by the first sync. Each later sync advances it by 0x100.
        public var initialCounter = "08ABBEC7"
        /// The counter the device puts on its own (status) frames.
        public var deviceCounter = "1A2B3C4D"
        public var maxAge: UInt32? = 60
        /// Reject control frames whose counter isn't exactly the last synced/accepted
        /// counter + 1. ASSUMPTION: real devices are believed to check the counter but the
        /// exact rule is unknown.
        public var strictCounter = true
        /// Message type for notifications pushed after a state change.
        public var notificationType: CoAPMessage.MessageType = .nonConfirmable
        /// Listen only on loopback (tests). The standalone tool can listen on all interfaces.
        public var loopbackOnly = true

        public init() {}
    }

    /// Scriptable faults. Counters decrement as they fire.
    public struct Faults: Sendable {
        /// Silently drop the next N requests to a path, as if lost on the network.
        public var dropRequests: [String: Int] = [:]
        /// Process the next N requests to a path but lose the response.
        public var dropResponses: [String: Int] = [:]
        /// Answer the next N control requests with `{"status":"failed"}`.
        public var failControls = 0
        /// Corrupt the digest of the next N status frames.
        public var corruptStatusDigests = 0
        /// Push-only firmware: never answer an Observe registration.
        public var ignoreStatusRequests = false
        /// Ignore everything (a wedged device).
        public var wedged = false

        public init() {}
    }

    public struct Request: Sendable, Hashable {
        public let path: String
        public let type: CoAPMessage.MessageType
        public let code: CoAPMessage.Code
        public let messageID: UInt16
        /// Which client socket it came from (a new value means a new source port).
        public let peer: Int
    }

    public private(set) var behavior: Behavior
    public var faults: Faults
    /// The device state, as it would appear in `state.reported`.
    public private(set) var reported: [String: JSONValue]
    /// Every request received, in order, including dropped ones.
    public private(set) var requests: [Request] = []
    /// The `desired` objects of accepted control requests.
    public private(set) var acceptedControls: [[String: JSONValue]] = []
    public private(set) var syncCount = 0

    private var listener: NWListener?
    private var peers: [Int: NWConnection] = [:]
    private var nextPeerID = 0
    private var clientCounter: PhilipsCounter?
    private var deviceCounter: PhilipsCounter
    private var syncedCounterValue: UInt64
    private var observers: [Observer] = []
    private var observeSequence: UInt32 = 1
    private var nextMessageID: UInt16 = 0x4000
    private var responseCache: [ResponseKey: [UInt8]] = [:]
    private let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    private var eventTask: Task<Void, Never>?

    private struct Observer {
        let peer: Int
        let token: [UInt8]
    }

    private struct ResponseKey: Hashable {
        let peer: Int
        let messageID: UInt16
    }

    private enum Event: Sendable {
        case connected(Int, NWConnection)
        case datagram(Int, [UInt8])
    }

    public init(reported: [String: JSONValue], behavior: Behavior = .init(), faults: Faults = .init()) {
        self.reported = reported
        self.behavior = behavior
        self.faults = faults
        // Force-unwraps are on constant configuration values; a bad value is a test bug.
        // swiftlint:disable force_try
        deviceCounter = try! PhilipsCounter(hex: behavior.deviceCounter)
        syncedCounterValue = try! PhilipsCounter(hex: behavior.initialCounter).value
        // swiftlint:enable force_try
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
    }

    // MARK: - Lifecycle

    /// Starts listening and returns the UDP port. Pass 0 for an ephemeral port.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if behavior.loopbackOnly {
            parameters.requiredInterfaceType = .loopback
        }
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        let sink = eventSink
        let idSource = PeerIDSource()
        listener.newConnectionHandler = { connection in
            let id = idSource.next()
            sink.yield(.connected(id, connection))
            connection.start(queue: .global())
            Self.receive(on: connection, id: id, sink: sink)
        }
        eventTask = Task {
            for await event in events {
                self.handle(event)
            }
        }
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case let .failed(error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        return boundPort
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in peers.values {
            connection.cancel()
        }
        peers.removeAll()
        eventTask?.cancel()
        eventSink.finish()
    }

    public func setFaults(_ update: @Sendable (inout Faults) -> Void) {
        update(&faults)
    }

    /// Changes device state (as if a button were pressed) and notifies observers.
    public func update(_ changes: [String: JSONValue]) {
        reported.merge(changes) { _, new in new }
        pushNotification()
    }

    /// Forgets the client's counter and observers, as a power cycle would. The next control
    /// frame is rejected until the client syncs again.
    public func simulateReboot() {
        clientCounter = nil
        observers.removeAll()
    }

    public func requests(to path: String) -> [Request] {
        requests.filter { $0.path == path }
    }

    // MARK: - Networking

    private nonisolated static func receive(on connection: NWConnection, id: Int, sink: AsyncStream<Event>.Continuation) {
        connection.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty {
                sink.yield(.datagram(id, Array(data)))
            }
            if error == nil {
                receive(on: connection, id: id, sink: sink)
            }
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case let .connected(id, connection):
            peers[id] = connection
        case let .datagram(peer, bytes):
            handleDatagram(bytes, from: peer)
        }
    }

    private func send(_ message: CoAPMessage, to peer: Int) {
        guard let connection = peers[peer], let bytes = try? message.encode() else { return }
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    private func allocateMessageID() -> UInt16 {
        defer { nextMessageID &+= 1 }
        return nextMessageID
    }

    // MARK: - Request handling

    private func handleDatagram(_ bytes: [UInt8], from peer: Int) {
        guard let message = try? CoAPMessage.decode(bytes) else { return }

        if message.type == .reset {
            // RST to a notification: the client cancelled its observation.
            observers.removeAll { $0.peer == peer }
            return
        }
        guard message.type == .confirmable || message.type == .nonConfirmable, message.code.isRequest else {
            return // ACKs of our notifications, etc.
        }

        let path = message.uriPath
        requests.append(Request(path: path, type: message.type, code: message.code, messageID: message.messageID, peer: peer))

        if faults.wedged { return }
        if let remaining = faults.dropRequests[path], remaining > 0 {
            faults.dropRequests[path] = remaining - 1
            return
        }
        // Duplicate (a retransmission): replay the cached response, don't re-execute.
        let cacheKey = ResponseKey(peer: peer, messageID: message.messageID)
        if let cached = responseCache[cacheKey] {
            peers[peer]?.send(content: Data(cached), completion: .idempotent)
            return
        }

        guard let response = respond(to: message, path: path, peer: peer) else { return }
        let bytes = (try? response.encode()) ?? []
        if message.type == .confirmable {
            responseCache[cacheKey] = bytes
        }
        if let remaining = faults.dropResponses[path], remaining > 0 {
            faults.dropResponses[path] = remaining - 1
            return
        }
        peers[peer]?.send(content: Data(bytes), completion: .idempotent)
    }

    /// Builds the response: piggybacked on an ACK for CON, a NON for NON (as aiocoap expects).
    private func reply(to request: CoAPMessage, code: CoAPMessage.Code, payload: [UInt8], options: [CoAPOption] = []) -> CoAPMessage {
        let confirmable = request.type == .confirmable
        return CoAPMessage(
            type: confirmable ? .acknowledgement : .nonConfirmable,
            code: code,
            messageID: confirmable ? request.messageID : allocateMessageID(),
            token: request.token,
            options: options,
            payload: payload
        )
    }

    private func respond(to message: CoAPMessage, path: String, peer: Int) -> CoAPMessage? {
        switch (path, message.code) {
        case ("/sys/dev/sync", .post):
            syncCount += 1
            if syncCount > 1 {
                syncedCounterValue = (syncedCounterValue + 0x100) & 0xFFFF_FFFF
            }
            let counter = PhilipsCounter.formatted(syncedCounterValue)
            clientCounter = try? PhilipsCounter(hex: counter)
            return reply(to: message, code: .content, payload: Array(counter.utf8))

        case ("/sys/dev/status", .get):
            if faults.ignoreStatusRequests { return nil }
            var options: [CoAPOption] = []
            if message.observe == 0 {
                observers.removeAll { $0.peer == peer && $0.token == message.token }
                observers.append(Observer(peer: peer, token: message.token))
                options.append(CoAPOption(.observe, uint: nextObserveSequence()))
            } else if message.observe == 1 {
                observers.removeAll { $0.peer == peer && $0.token == message.token }
            }
            if let maxAge = behavior.maxAge {
                options.append(CoAPOption(.maxAge, uint: maxAge))
            }
            return reply(to: message, code: .content, payload: statusFrame(), options: options)

        case ("/sys/dev/control", .post):
            let result = applyControl(message.payload)
            let response = reply(to: message, code: .changed, payload: Array(result.utf8))
            if result == #"{"status":"success"}"# {
                // Notify after the response is on its way.
                Task { self.pushNotification() }
            }
            return response

        default:
            return reply(to: message, code: .notFound, payload: [])
        }
    }

    private func applyControl(_ payload: [UInt8]) -> String {
        let failed = #"{"status":"failed"}"#
        if faults.failControls > 0 {
            faults.failControls -= 1
            return failed
        }
        guard let opened = try? LegacyPhilipsCipher.open(String(decoding: payload, as: UTF8.self)),
              let frameCounter = try? PhilipsCounter(hex: opened.counter)
        else {
            return failed
        }
        if behavior.strictCounter {
            guard let expected = try? clientCounter?.incremented(), expected.hex == frameCounter.hex else {
                return failed
            }
        }
        clientCounter = frameCounter
        guard let document = try? JSONValue.parse(opened.plaintext),
              let desired = document.objectValue?["state"]?.objectValue?["desired"]?.objectValue,
              desired["CommandType"] == "app"
        else {
            return failed
        }
        let changes = desired.filter { !["CommandType", "DeviceId", "EnduserId"].contains($0.key) }
        acceptedControls.append(desired)
        reported.merge(changes) { _, new in new }
        return #"{"status":"success"}"#
    }

    private func statusFrame() -> [UInt8] {
        let json = JSONValue.object(["state": .object(["reported": .object(reported)])]).pythonJSON
        // The device advances its own counter for each frame it sends (ASSUMPTION).
        let counter = (try? deviceCounter.advance()) ?? deviceCounter
        guard var frame = try? LegacyPhilipsCipher.seal(json, counter: counter) else { return [] }
        if faults.corruptStatusDigests > 0 {
            faults.corruptStatusDigests -= 1
            let last = frame.removeLast()
            frame.append(last == "0" ? "1" : "0")
        }
        return Array(frame.utf8)
    }

    private func nextObserveSequence() -> UInt32 {
        defer { observeSequence = (observeSequence + 1) & 0xFF_FFFF }
        return observeSequence
    }

    private func pushNotification() {
        guard !observers.isEmpty, !faults.wedged else { return }
        let payload = statusFrame()
        let sequence = nextObserveSequence()
        for observer in observers {
            var options = [CoAPOption(.observe, uint: sequence)]
            if let maxAge = behavior.maxAge {
                options.append(CoAPOption(.maxAge, uint: maxAge))
            }
            let notification = CoAPMessage(
                type: behavior.notificationType,
                code: .content,
                messageID: allocateMessageID(),
                token: observer.token,
                options: options,
                payload: payload
            )
            send(notification, to: observer.peer)
        }
    }
}

// MARK: - Small helpers

private final class PeerIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

extension PhilipsCounter {
    static func formatted(_ value: UInt64) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }
}
