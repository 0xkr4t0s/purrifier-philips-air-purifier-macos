import CoAPCore
import Testing
@testable import AirLink

@Suite(.timeLimit(.minutes(1)))
struct CoAPTransportTests {
    static func fastConfiguration() -> CoAPTransport.Configuration {
        var configuration = CoAPTransport.Configuration()
        configuration.ackTimeout = .milliseconds(20)
        return configuration
    }

    static func statusRequest(_ type: CoAPMessage.MessageType = .confirmable) -> CoAPMessage {
        var message = CoAPMessage(type: type, code: .get, messageID: 0)
        message.setURIPath("/sys/dev/status")
        return message
    }

    @Test func piggybackedResponse() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        async let response = transport.request(Self.statusRequest(), timeout: .seconds(2))

        let request = try #require(try await channel.waitForSent(count: 1).first)
        #expect(request.type == .confirmable)
        #expect((4 ... 8).contains(request.token.count))
        try channel.inject(CoAPMessage(
            type: .acknowledgement, code: .content, messageID: request.messageID, token: request.token, payload: [0x41]
        ))
        let result = try await response
        #expect(result.payload == [0x41])
        #expect(await transport.pendingExchangeCount == 0)
    }

    @Test func separateResponseIsAcknowledged() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        async let response = transport.request(Self.statusRequest(), timeout: .seconds(2))

        let request = try #require(try await channel.waitForSent(count: 1).first)
        try channel.inject(.empty(type: .acknowledgement, messageID: request.messageID))
        try channel.inject(CoAPMessage(
            type: .confirmable, code: .content, messageID: 0x9999, token: request.token, payload: [1]
        ))
        #expect(try await response.payload == [1])

        let sent = try await channel.waitForSent(count: 2)
        #expect(sent.last == .empty(type: .acknowledgement, messageID: 0x9999))
        // The empty ACK stopped retransmission: nothing else goes out.
        try await Task.sleep(for: .milliseconds(150))
        #expect(channel.sent.count == 2)
    }

    @Test func retransmitsWithBackoffThenTimesOut() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        let start = ContinuousClock.now
        await #expect(throws: TransportError.timeout) {
            try await transport.request(Self.statusRequest(), timeout: .seconds(5))
        }
        let elapsed = ContinuousClock.now - start
        let sent = channel.sent
        // 1 transmission + MAX_RETRANSMIT (4) retransmissions, all the same datagram.
        #expect(sent.count == 5)
        #expect(Set(sent.map(\.messageID)).count == 1)
        #expect(Set(sent.map(\.token)).count == 1)
        // 20 + 40 + 80 + 160 ms of backoff plus a final 320 ms wait: well under the 5 s deadline.
        #expect(elapsed >= .milliseconds(600))
        #expect(elapsed < .seconds(3))
    }

    @Test func nonConfirmableIsNotRetransmitted() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        await #expect(throws: TransportError.timeout) {
            try await transport.request(Self.statusRequest(.nonConfirmable), timeout: .milliseconds(200))
        }
        #expect(channel.sent.count == 1)
    }

    @Test func nonConfirmableResponseMatchedByToken() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        async let response = transport.request(Self.statusRequest(.nonConfirmable), timeout: .seconds(2))
        let request = try #require(try await channel.waitForSent(count: 1).first)
        try channel.inject(CoAPMessage(type: .nonConfirmable, code: .content, messageID: 7, token: request.token))
        #expect(try await response.code == .content)
        // NON responses are not ACKed.
        #expect(channel.sent.count == 1)
    }

    @Test func resetFailsTheRequest() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        let response = Task { try await transport.request(Self.statusRequest(), timeout: .seconds(2)) }
        let request = try #require(try await channel.waitForSent(count: 1).first)
        try channel.inject(.empty(type: .reset, messageID: request.messageID))
        await #expect(throws: TransportError.reset) { try await response.value }
    }

    @Test func mismatchedTokenOnAckIsIgnored() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        await #expect(throws: TransportError.timeout) {
            async let response = transport.request(Self.statusRequest(), timeout: .milliseconds(300))
            let request = try #require(try await channel.waitForSent(count: 1).first)
            try channel.inject(CoAPMessage(
                type: .acknowledgement, code: .content, messageID: request.messageID, token: [0xEE]
            ))
            _ = try await response
        }
    }

    @Test func unknownTokenIsRejectedWithReset() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        // Start the receive loop with a request that we let time out.
        _ = try? await transport.request(Self.statusRequest(.nonConfirmable), timeout: .milliseconds(10))
        try channel.inject(CoAPMessage(type: .confirmable, code: .content, messageID: 0x0101, token: [9, 9, 9, 9]))
        let sent = try await channel.waitForSent(count: 2)
        #expect(sent.last == .empty(type: .reset, messageID: 0x0101))
    }

    @Test func malformedConfirmableIsRejectedWithReset() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        _ = try? await transport.request(Self.statusRequest(.nonConfirmable), timeout: .milliseconds(10))
        // CON with reserved option nibble 15.
        channel.inject(.datagram([0x40, 0x45, 0x12, 0x34, 0xF1]))
        let sent = try await channel.waitForSent(count: 2)
        #expect(sent.last == .empty(type: .reset, messageID: 0x1234))
    }

    @Test func observationDeliversNotificationsInOrderAndDeduplicates() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        var registration = Self.statusRequest()
        registration.observe = 0
        let observation = try await transport.observe(registration)
        let request = try #require(try await channel.waitForSent(count: 1).first)
        #expect(request.observe == 0)

        func notification(mid: UInt16, sequence: UInt32, type: CoAPMessage.MessageType = .confirmable) -> CoAPMessage {
            var message = CoAPMessage(
                type: type,
                code: .content,
                messageID: mid,
                token: request.token,
                payload: [UInt8(sequence)]
            )
            message.observe = sequence
            return message
        }
        var piggybacked = notification(mid: request.messageID, sequence: 5)
        piggybacked.type = .acknowledgement
        try channel.inject(piggybacked)
        try channel.inject(notification(mid: 0x0A01, sequence: 6))
        try channel.inject(notification(mid: 0x0A01, sequence: 6)) // duplicate datagram
        try channel.inject(notification(mid: 0x0A02, sequence: 4)) // stale (reordered)
        try channel.inject(notification(mid: 0x0A03, sequence: 7, type: .nonConfirmable))

        var received: [UInt8] = []
        for try await message in observation.messages {
            received.append(contentsOf: message.payload)
            if received.count == 3 {
                break
            }
        }
        #expect(received == [5, 6, 7])

        // Each CON notification was ACKed, the duplicate ACKed again; the NON wasn't.
        let acks = channel.sent.filter { $0.type == .acknowledgement }.map(\.messageID)
        #expect(acks == [0x0A01, 0x0A01, 0x0A02])
    }

    @Test func cancelledObservationRejectsLaterNotifications() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        var registration = Self.statusRequest(.nonConfirmable)
        registration.observe = 0
        let observation = try await transport.observe(registration)
        let request = try #require(try await channel.waitForSent(count: 1).first)
        await transport.cancelObservation(token: observation.token)
        #expect(await transport.pendingExchangeCount == 0)

        var late = CoAPMessage(type: .nonConfirmable, code: .content, messageID: 0x0B01, token: request.token)
        late.observe = 9
        try channel.inject(late)
        let sent = try await channel.waitForSent(count: 2)
        #expect(sent.last == .empty(type: .reset, messageID: 0x0B01))
    }

    @Test func responseWithoutObserveEndsTheObservation() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        var registration = Self.statusRequest()
        registration.observe = 0
        let observation = try await transport.observe(registration)
        let request = try #require(try await channel.waitForSent(count: 1).first)
        try channel.inject(CoAPMessage(
            type: .acknowledgement,
            code: .content,
            messageID: request.messageID,
            token: request.token
        ))
        var count = 0
        for try await _ in observation.messages {
            count += 1
        }
        #expect(count == 1)
    }

    @Test func connectionRefusedFailsFast() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        await #expect(throws: TransportError.connectionRefused) {
            async let response = transport.request(Self.statusRequest(), timeout: .seconds(10))
            _ = try await channel.waitForSent(count: 1)
            channel.inject(.error(.connectionRefused))
            _ = try await response
        }
    }

    @Test func cancellationCleansUp() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        let task = Task { try await transport.request(Self.statusRequest(), timeout: .seconds(10)) }
        _ = try await channel.waitForSent(count: 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.pendingExchangeCount == 0)
    }

    @Test func closeFailsPendingAndRefusesNewRequests() async throws {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        let response = Task { try await transport.request(Self.statusRequest(), timeout: .seconds(10)) }
        _ = try await channel.waitForSent(count: 1)
        await transport.close()
        await #expect(throws: TransportError.closed) { try await response.value }
        await #expect(throws: TransportError.closed) {
            try await transport.request(Self.statusRequest(), timeout: .seconds(1))
        }
    }

    @Test func messageIDsIncrementAndTokensDiffer() async {
        let channel = MockChannel()
        let transport = CoAPTransport(channel: channel, configuration: Self.fastConfiguration())
        for _ in 0 ..< 3 {
            _ = try? await transport.request(Self.statusRequest(.nonConfirmable), timeout: .milliseconds(5))
        }
        let sent = channel.sent
        #expect(sent.count == 3)
        #expect(sent[1].messageID == sent[0].messageID &+ 1)
        #expect(sent[2].messageID == sent[1].messageID &+ 1)
        #expect(Set(sent.map(\.token)).count == 3)
    }

    @Test(arguments: [
        (UInt32(5), UInt32(4), true), (4, 5, false), (5, 5, false),
        (1, 0xFFFFFF, true), // wrapped around
        (0xFFFFFF, 1, false),
    ] as [(UInt32, UInt32, Bool)])
    func observeFreshness(new: UInt32, old: UInt32, fresh: Bool) {
        let now = ContinuousClock.now
        #expect(CoAPTransport.isFresh(new, receivedAt: now, comparedTo: old, receivedAt: now) == fresh)
        // Anything more than 128 s later is fresh regardless.
        #expect(CoAPTransport.isFresh(
            new,
            receivedAt: now.advanced(by: .seconds(129)),
            comparedTo: old,
            receivedAt: now
        ))
    }
}
