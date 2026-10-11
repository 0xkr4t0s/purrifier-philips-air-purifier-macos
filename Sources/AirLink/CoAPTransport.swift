import CoAPCore

/// A minimal CoAP client endpoint (RFC 7252 + RFC 7641 Observe) for one peer.
///
/// Responsibilities:
/// - assigns message IDs and random tokens, and matches replies by message ID (ACK/RST)
///   or by token (separate responses and notifications);
/// - retransmits confirmable messages with exponential backoff
///   (`ACK_TIMEOUT × 2ⁿ`, up to `MAX_RETRANSMIT` times) until acknowledged;
/// - ACKs confirmable responses and notifications, and detects duplicates by message ID;
/// - rejects messages with unknown tokens with RST, which is also how a cancelled
///   observation is ended on the device side (RFC 7641 §3.6);
/// - puts a deadline on every request. Nothing here waits forever.
public actor CoAPTransport {
    public struct Configuration: Sendable {
        /// RFC 7252 `ACK_TIMEOUT`.
        public var ackTimeout: Duration = .seconds(2)
        /// RFC 7252 `ACK_RANDOM_FACTOR`. The RFC default is 1.5; 1.0 gives the fixed
        /// `2 s × 2ⁿ` schedule, which makes debug traces easier to compare.
        public var ackRandomFactor: Double = 1.0
        /// RFC 7252 `MAX_RETRANSMIT`.
        public var maxRetransmit = 4
        /// RFC 7252 allows 0–8 bytes; random 4–8 bytes keeps tokens unguessable-ish and unique.
        public var tokenLength: ClosedRange<Int> = 4 ... 8
        /// How long received message IDs are remembered for deduplication
        /// (RFC 7252 `EXCHANGE_LIFETIME`, 247 s).
        public var deduplicationWindow: Duration = .seconds(247)

        public init() {}
    }

    /// A registered observation. Iterate `messages`; call `CoAPTransport.cancelObservation`
    /// (or stop iterating) to end it.
    public struct Observation: Sendable {
        public let token: [UInt8]
        public let messages: AsyncThrowingStream<CoAPMessage, any Error>
    }

    private struct TokenKey: Hashable {
        let bytes: [UInt8]
    }

    private enum Waiter {
        case response(CheckedContinuation<CoAPMessage, any Error>)
        case observation(AsyncThrowingStream<CoAPMessage, any Error>.Continuation)
    }

    private struct Exchange {
        var waiter: Waiter
        var messageID: UInt16
        var acknowledged = false
        var driver: Task<Void, Never>?
        var lastObserve: (sequence: UInt32, at: ContinuousClock.Instant)?
    }

    private let channel: any DatagramChannel
    private let configuration: Configuration
    private let logger: WireLogger?
    private let clock = ContinuousClock()

    private var exchanges: [TokenKey: Exchange] = [:]
    private var tokenForMessageID: [UInt16: TokenKey] = [:]
    private var nextMessageID: UInt16
    private var receiveTask: Task<Void, Never>?
    /// Message IDs recently received from the peer, with the reply we sent (for duplicates).
    private var recentlyReceived: [UInt16: (at: ContinuousClock.Instant, reply: [UInt8]?)] = [:]
    private var isClosed = false

    public init(channel: any DatagramChannel, configuration: Configuration = .init(), logger: WireLogger? = nil) {
        self.channel = channel
        self.configuration = configuration
        self.logger = logger
        nextMessageID = .random(in: .min ... .max)
    }

    /// Number of requests and observations in flight (for tests and diagnostics).
    public var pendingExchangeCount: Int { exchanges.count }

    // MARK: - Requests

    /// Sends a request and waits for its response.
    ///
    /// The message ID and token of `template` are replaced. For a confirmable request the
    /// response may arrive piggybacked on the ACK or separately; both are handled.
    ///
    /// - Throws: `TransportError` (`.timeout` once `timeout` elapses), or `CancellationError`.
    public func request(_ template: CoAPMessage, timeout: Duration) async throws -> CoAPMessage {
        let (key, message, bytes) = try prepare(template)
        let deadline = clock.now.advanced(by: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    key,
                    waiter: .response(continuation),
                    messageID: message.messageID,
                    bytes: bytes,
                    confirmable: message.type == .confirmable,
                    deadline: deadline
                )
            }
        } onCancel: {
            Task { await self.fail(key, with: CancellationError()) }
        }
    }

    /// Registers an observation (the template should carry `Observe: 0`). The stream yields
    /// the first response and every later notification. It finishes when the server stops
    /// observing (a response without an Observe option, or an error code), and throws on
    /// RST, connection failure, or, for a CON registration, if it's never acknowledged.
    public func observe(_ template: CoAPMessage) throws -> Observation {
        let (key, message, bytes) = try prepare(template)
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: CoAPMessage.self,
            throwing: (any Error).self,
            bufferingPolicy: .bufferingNewest(32)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancelObservation(token: key.bytes) }
        }
        register(
            key,
            waiter: .observation(continuation),
            messageID: message.messageID,
            bytes: bytes,
            confirmable: message.type == .confirmable,
            deadline: nil
        )
        return Observation(token: message.token, messages: stream)
    }

    /// Stops delivering notifications for `token`. Any further notification from the device
    /// is answered with RST, which removes us from its observer list.
    public func cancelObservation(token: [UInt8]) {
        guard let exchange = removeExchange(TokenKey(bytes: token)) else { return }
        if case let .observation(continuation) = exchange.waiter {
            continuation.finish()
        }
    }

    /// Fails everything in flight and closes the channel. The transport can't be reused.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        for key in Array(exchanges.keys) {
            fail(key, with: TransportError.closed)
        }
        receiveTask?.cancel()
        channel.close()
    }

    // MARK: - Exchange bookkeeping

    private func prepare(_ template: CoAPMessage) throws -> (TokenKey, CoAPMessage, [UInt8]) {
        guard !isClosed else { throw TransportError.closed }
        startReceivingIfNeeded()
        var message = template
        message.messageID = allocateMessageID()
        message.token = newToken()
        do {
            return try (TokenKey(bytes: message.token), message, message.encode())
        } catch {
            throw TransportError.encodingFailed(error)
        }
    }

    private func register(
        _ key: TokenKey,
        waiter: Waiter,
        messageID: UInt16,
        bytes: [UInt8],
        confirmable: Bool,
        deadline: ContinuousClock.Instant?
    ) {
        guard !Task.isCancelled else {
            Self.complete(waiter, with: .failure(CancellationError()))
            return
        }
        exchanges[key] = Exchange(waiter: waiter, messageID: messageID)
        tokenForMessageID[messageID] = key
        exchanges[key]?.driver = Task {
            await self.drive(key, bytes: bytes, confirmable: confirmable, deadline: deadline)
        }
    }

    /// Sends the message, retransmits it while it's unacknowledged, and enforces the deadline.
    private func drive(
        _ key: TokenKey,
        bytes: [UInt8],
        confirmable: Bool,
        deadline: ContinuousClock.Instant?
    ) async {
        var interval = configuration.ackTimeout * Double.random(in: 1 ... max(1, configuration.ackRandomFactor))
        var retransmissions = 0
        guard await transmit(bytes, for: key) else { return }

        while exchanges[key] != nil {
            let awaitingAck = confirmable && exchanges[key]?.acknowledged == false
            let mayRetransmit = awaitingAck && retransmissions < configuration.maxRetransmit
            let retransmitAt = mayRetransmit ? clock.now.advanced(by: interval) : nil
            // Out of retransmissions: allow one more interval for a late ACK, then give up.
            let giveUpAt = awaitingAck && !mayRetransmit ? clock.now.advanced(by: interval) : nil
            guard let wake = [retransmitAt, giveUpAt, deadline].compactMap(\.self).min() else {
                return // acknowledged observation, or NON without deadline: nothing to time
            }
            do {
                try await Task.sleep(until: wake, clock: clock)
            } catch {
                return // the exchange finished and cancelled us
            }
            guard let exchange = exchanges[key] else { return }
            let now = clock.now
            if let deadline, now >= deadline {
                fail(key, with: TransportError.timeout)
                return
            }
            if let giveUpAt, now >= giveUpAt, !exchange.acknowledged {
                fail(key, with: TransportError.timeout)
                return
            }
            if let retransmitAt, now >= retransmitAt, !exchange.acknowledged {
                retransmissions += 1
                interval *= 2
                logger?(.note("retransmission \(retransmissions)/\(configuration.maxRetransmit) of mid=0x\(Hex.encode(exchange.messageID))"))
                guard await transmit(bytes, for: key) else { return }
            }
        }
    }

    private func transmit(_ bytes: [UInt8], for key: TokenKey) async -> Bool {
        logger?(.sent(bytes))
        do {
            try await channel.send(bytes)
            return true
        } catch {
            fail(key, with: error)
            return false
        }
    }

    private func removeExchange(_ key: TokenKey) -> Exchange? {
        guard let exchange = exchanges.removeValue(forKey: key) else { return nil }
        if tokenForMessageID[exchange.messageID] == key {
            tokenForMessageID.removeValue(forKey: exchange.messageID)
        }
        exchange.driver?.cancel()
        return exchange
    }

    private func fail(_ key: TokenKey, with error: any Error) {
        guard let exchange = removeExchange(key) else { return }
        Self.complete(exchange.waiter, with: .failure(error))
    }

    private static func complete(_ waiter: Waiter, with result: Result<CoAPMessage, any Error>) {
        switch (waiter, result) {
        case let (.response(continuation), _):
            continuation.resume(with: result)
        case let (.observation(continuation), .success(message)):
            continuation.yield(message)
            continuation.finish()
        case let (.observation(continuation), .failure(error)):
            continuation.finish(throwing: error)
        }
    }

    private func allocateMessageID() -> UInt16 {
        defer { nextMessageID &+= 1 }
        return nextMessageID
    }

    private func newToken() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        while true {
            let length = Int.random(in: configuration.tokenLength, using: &generator)
            let token = (0 ..< length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            if exchanges[TokenKey(bytes: token)] == nil { return token }
        }
    }

    // MARK: - Receiving

    private func startReceivingIfNeeded() {
        guard receiveTask == nil else { return }
        let events = channel.events
        receiveTask = Task {
            for await event in events {
                self.handle(event)
            }
            self.channelEnded()
        }
    }

    private func handle(_ event: ChannelEvent) {
        switch event {
        case let .datagram(bytes):
            handleDatagram(bytes)
        case .error(.connectionRefused):
            // Nothing listens on the port: fail fast instead of retransmitting into the void.
            for key in Array(exchanges.keys) {
                fail(key, with: TransportError.connectionRefused)
            }
        case let .error(error):
            logger?(.note("channel error: \(error)"))
        }
    }

    private func channelEnded() {
        guard !isClosed else { return }
        isClosed = true
        for key in Array(exchanges.keys) {
            fail(key, with: TransportError.closed)
        }
    }

    private func handleDatagram(_ bytes: [UInt8]) {
        logger?(.received(bytes))
        let message: CoAPMessage
        do {
            message = try CoAPMessage.decode(bytes)
        } catch {
            logger?(.note("dropped malformed datagram: \(error)"))
            // RFC 7252 §4.2: reject a malformed CON with RST if its message ID is readable.
            if bytes.count >= 4, bytes[0] >> 6 == CoAPMessage.version, (bytes[0] >> 4) & 0x03 == 0 {
                sendEmpty(.reset, messageID: UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
            }
            return
        }
        switch message.type {
        case .acknowledgement, .reset:
            handleReply(message)
        case .confirmable, .nonConfirmable:
            handlePeerMessage(message)
        }
    }

    /// ACK or RST: matched to our message by message ID.
    private func handleReply(_ message: CoAPMessage) {
        guard let key = tokenForMessageID[message.messageID], exchanges[key] != nil else {
            return // a late or duplicate reply to an exchange that's already over
        }
        if message.type == .reset {
            fail(key, with: TransportError.reset)
            return
        }
        exchanges[key]?.acknowledged = true
        if message.code.isEmpty {
            return // empty ACK: the response will follow separately
        }
        guard message.token == key.bytes else {
            logger?(.note("ACK mid=0x\(Hex.encode(message.messageID)) has a mismatched token; ignored"))
            return
        }
        deliver(message, to: key)
    }

    /// CON or NON from the device: a separate response or a notification, matched by token.
    private func handlePeerMessage(_ message: CoAPMessage) {
        let now = clock.now
        pruneDeduplicationCache(now: now)
        if let seen = recentlyReceived[message.messageID] {
            // Duplicate: repeat our earlier reply for a CON, never deliver twice.
            if message.type == .confirmable, let reply = seen.reply {
                sendRaw(reply)
            }
            return
        }

        let key = TokenKey(bytes: message.token)
        let expected = exchanges[key] != nil && message.code.isResponse
        let reply: [UInt8]?
        if expected {
            reply = message.type == .confirmable ? Self.emptyBytes(.acknowledgement, messageID: message.messageID) : nil
        } else {
            // Unknown token (e.g. a notification for an observation we cancelled) or an
            // unexpected request: reject it. RFC 7641 §3.6 lets RST answer a NON too.
            reply = Self.emptyBytes(.reset, messageID: message.messageID)
        }
        recentlyReceived[message.messageID] = (now, reply)
        if let reply {
            sendRaw(reply)
        }
        if expected {
            deliver(message, to: key)
        }
    }

    private func deliver(_ message: CoAPMessage, to key: TokenKey) {
        guard let exchange = exchanges[key] else { return }
        switch exchange.waiter {
        case let .response(continuation):
            _ = removeExchange(key)
            continuation.resume(returning: message)
        case let .observation(continuation):
            guard let sequence = message.observe else {
                // No Observe option: the device didn't register us (or stopped). Deliver and end.
                _ = removeExchange(key)
                continuation.yield(message)
                continuation.finish()
                return
            }
            let now = clock.now
            if let last = exchange.lastObserve,
               !Self.isFresh(sequence, receivedAt: now, comparedTo: last.sequence, receivedAt: last.at)
            {
                logger?(.note("dropped out-of-order notification (Observe \(sequence) after \(last.sequence))"))
                return
            }
            exchanges[key]?.lastObserve = (sequence, now)
            exchanges[key]?.acknowledged = true
            continuation.yield(message)
            if !message.code.isSuccess {
                _ = removeExchange(key)
                continuation.finish()
            }
        }
    }

    /// RFC 7641 §3.4: is notification `new` fresher than `old`? Sequence numbers are 24-bit
    /// and wrap; anything 128 s later is accepted regardless.
    static func isFresh(
        _ new: UInt32,
        receivedAt newTime: ContinuousClock.Instant,
        comparedTo old: UInt32,
        receivedAt oldTime: ContinuousClock.Instant
    ) -> Bool {
        let half: UInt32 = 1 << 23
        return (old < new && new - old < half)
            || (old > new && old - new > half)
            || newTime > oldTime.advanced(by: .seconds(128))
    }

    private func pruneDeduplicationCache(now: ContinuousClock.Instant) {
        guard recentlyReceived.count > 64 else { return }
        let cutoff = now.advanced(by: .zero - configuration.deduplicationWindow)
        recentlyReceived = recentlyReceived.filter { $0.value.at > cutoff }
    }

    private func sendEmpty(_ type: CoAPMessage.MessageType, messageID: UInt16) {
        sendRaw(Self.emptyBytes(type, messageID: messageID))
    }

    private func sendRaw(_ bytes: [UInt8]) {
        logger?(.sent(bytes))
        let channel = channel
        Task {
            try? await channel.send(bytes)
        }
    }

    private static func emptyBytes(_ type: CoAPMessage.MessageType, messageID: UInt16) -> [UInt8] {
        // An Empty message always encodes; the force-try can't fail.
        // swiftlint:disable:next force_try
        try! CoAPMessage.empty(type: type, messageID: messageID).encode()
    }
}
