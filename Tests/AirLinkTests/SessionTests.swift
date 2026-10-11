import AirLink
import CoAPCore
import FakePurifier
import Foundation
import PurifierModel
import Testing
import TestSupport

/// End-to-end tests: `PurifierSession` talking real UDP (loopback) to `FakePurifier`.
@Suite(.timeLimit(.minutes(1)))
struct SessionTests {
    static func auto() throws -> [String: JSONValue] {
        try #require(Fixtures.decode(JSONValue.self, from: "ac0850-11/auto.json").objectValue)
    }

    /// Starts a simulator and a session with short timeouts so failure paths run quickly.
    static func makePair(
        reported: [String: JSONValue]? = nil,
        faults: FakePurifier.Faults = .init(),
        messageType: CoAPMessage.MessageType = .confirmable,
        logger: WireLogger? = nil
    ) async throws -> (FakePurifier, PurifierSession) {
        let fake = try FakePurifier(reported: reported ?? auto(), faults: faults)
        let port = try await fake.start()
        var configuration = SessionConfiguration(host: "127.0.0.1", port: port)
        configuration.syncTimeout = .milliseconds(800)
        configuration.statusTimeout = .milliseconds(1200)
        configuration.controlTimeout = .milliseconds(1000)
        configuration.transport.ackTimeout = .milliseconds(100)
        configuration.messageType = messageType
        return (fake, PurifierSession(configuration: configuration, logger: logger))
    }

    // MARK: Happy path

    @Test(arguments: [CoAPMessage.MessageType.confirmable, .nonConfirmable])
    func statusMatchesDeviceState(messageType: CoAPMessage.MessageType) async throws {
        let (fake, session) = try await Self.makePair(messageType: messageType)
        defer { Task { await fake.stop(); await session.close() } }

        let reported = try await session.status()
        #expect(try reported == (Self.auto()))
        #expect(await session.generation == .gen3)
        #expect(await session.counter?.hex == "08ABBEC7")
        #expect(await session.lastMaxAge == 60)
        #expect(await fake.requests.map(\.path) == [PurifierSession.Path.sync, PurifierSession.Path.status])
        #expect(await fake.requests.allSatisfy { $0.type == messageType })
    }

    @Test func typedState() async throws {
        let (fake, session) = try await Self.makePair()
        defer { Task { await fake.stop(); await session.close() } }
        let state = try await session.state()
        #expect(state.isOn == true)
        #expect(state.mode == .auto)
        #expect(state.device.model == "AC0850/11")
    }

    @Test func setModeReadsGenerationFirstThenWrites() async throws {
        let (fake, session) = try await Self.makePair()
        defer { Task { await fake.stop(); await session.close() } }

        try await session.send(.mode(.sleep))

        #expect(await fake.requests.map(\.path) == [
            PurifierSession.Path.sync, PurifierSession.Path.status, PurifierSession.Path.control,
        ])
        let desired = try #require(await fake.acceptedControls.last)
        #expect(desired == [
            "CommandType": "app", "DeviceId": "", "EnduserId": "", "D03102": 1, "D0310C": 17,
        ])
        #expect(await fake.reported["D0310C"] == 17)
        #expect(await session.counter?.hex == "08ABBEC8") // advanced once, before the send
    }

    @Test func rawSetAndCounterAdvancesPerSend() async throws {
        let (fake, session) = try await Self.makePair()
        defer { Task { await fake.stop(); await session.close() } }
        try await session.send(.raw([DesiredValue("D0310C", 18)]))
        try await session.send(.power(false))
        #expect(await session.counter?.hex == "08ABBEC9")
        #expect(await fake.reported["D0310C"] == 18)
        #expect(await fake.reported["D03102"] == 0)
        #expect(await fake.syncCount == 1)
    }

    @Test func observeStreamsUpdates() async throws {
        let (fake, session) = try await Self.makePair()
        defer { Task { await fake.stop(); await session.close() } }
        var iterator = await session.observe().makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?["D03221"] == 3)
        await fake.update(["D03221": 42])
        let second = try await iterator.next()
        #expect(second?["D03221"] == 42)
    }

    @Test func debugLoggerSeesDatagramsAndDecryptedJSON() async throws {
        let log = EventLog()
        let (fake, session) = try await Self.makePair(logger: { log.append($0) })
        defer { Task { await fake.stop(); await session.close() } }
        try await session.send(.mode(.turbo))
        let events = log.events
        #expect(events.contains {
            if case .sent = $0 {
                true
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .received = $0 {
                true
            } else {
                false
            }
        })
        let outgoing = events.compactMap { event -> String? in
            if case let .decrypted(.outgoing, json) = event {
                json
            } else {
                nil
            }
        }
        let expected = #"{"state": {"desired": {"CommandType": "app", "DeviceId": "", "EnduserId": "", "#
            + #""D03102": 1, "D0310C": 18}}}"#
        #expect(outgoing == [expected])
    }

    // MARK: Faults

    @Test func droppedSyncRequestIsRetransmitted() async throws {
        var faults = FakePurifier.Faults()
        faults.dropRequests[PurifierSession.Path.sync] = 1
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        try await session.sync()
        let syncs = await fake.requests(to: PurifierSession.Path.sync)
        #expect(syncs.count == 2)
        #expect(syncs[0].messageID == syncs[1].messageID) // a retransmission, not a new request
        #expect(await fake.syncCount == 1)
    }

    @Test func droppedControlResponseIsNotAppliedTwice() async throws {
        var faults = FakePurifier.Faults()
        faults.dropResponses[PurifierSession.Path.control] = 1
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        try await session.send(.mode(.turbo))
        let controls = await fake.requests(to: PurifierSession.Path.control)
        #expect(controls.count == 2)
        #expect(controls[0].messageID == controls[1].messageID)
        #expect(await fake.acceptedControls.count == 1)
    }

    @Test func nonSuccessControlResyncsOnFreshSocketAndRetries() async throws {
        var faults = FakePurifier.Faults()
        faults.failControls = 1
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        try await session.send(.mode(.sleep))
        #expect(await fake.syncCount == 2)
        #expect(await fake.acceptedControls.count == 1)
        let controls = await fake.requests(to: PurifierSession.Path.control)
        #expect(controls.count == 2)
        #expect(controls[0].peer != controls[1].peer) // resync opened a new socket
        #expect(await session.counter?.hex == "08ABBFC8") // second sync counter + 1
    }

    @Test func persistentControlFailureThrowsAfterOneRetry() async throws {
        var faults = FakePurifier.Faults()
        faults.failControls = 5
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        await #expect(throws: PurifierError.controlRejected(response: #"{"status":"failed"}"#)) {
            try await session.send(.mode(.sleep))
        }
        #expect(await fake.requests(to: PurifierSession.Path.control).count == 2)
        #expect(await fake.syncCount == 2)
    }

    @Test func rebootedDeviceRejectsStaleCounterThenRecovers() async throws {
        let (fake, session) = try await Self.makePair()
        defer { Task { await fake.stop(); await session.close() } }
        try await session.send(.mode(.sleep))
        await fake.simulateReboot()
        try await session.send(.mode(.turbo))
        #expect(await fake.reported["D0310C"] == 18)
        #expect(await fake.syncCount == 2)
    }

    @Test func digestMismatchTriggersResync() async throws {
        var faults = FakePurifier.Faults()
        faults.corruptStatusDigests = 1
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        let reported = try await session.status()
        #expect(reported["D01S05"] == "AC0850/11")
        #expect(await fake.syncCount == 2)
    }

    @Test func persistentDigestMismatchThrows() async throws {
        var faults = FakePurifier.Faults()
        faults.corruptStatusDigests = 5
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        await #expect(throws: PurifierError.crypto(operation: "status", .digestMismatch)) {
            try await session.status()
        }
    }

    @Test func wedgedDeviceTimesOutWithAdvice() async throws {
        var faults = FakePurifier.Faults()
        faults.wedged = true
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        let start = ContinuousClock.now
        do {
            _ = try await session.status()
            Issue.record("expected a timeout")
        } catch {
            guard case let .timeout(operation, _, _) = error else {
                Issue.record("expected .timeout, got \(error)")
                return
            }
            #expect(operation == "sync")
            #expect(error.localizedDescription.contains("power-cycle"))
        }
        // sync (0.8 s) + resync (0.8 s), never hanging.
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func pushOnlyFirmwareTimesOutOnStatus() async throws {
        var faults = FakePurifier.Faults()
        faults.ignoreStatusRequests = true
        let (fake, session) = try await Self.makePair(faults: faults)
        defer { Task { await fake.stop(); await session.close() } }

        await #expect(throws: PurifierError.self) { try await session.status() }
        #expect(await fake.syncCount == 2) // sync worked; status didn't (TODO(M2): pushOnly)
    }

    @Test func unverifiedGen2WriteIsRefusedLocally() async throws {
        let gen2 = try #require(Fixtures.decode(JSONValue.self, from: "generations/gen2-ac0850-20.json").objectValue)
        let (fake, session) = try await Self.makePair(reported: gen2)
        defer { Task { await fake.stop(); await session.close() } }

        await #expect(throws: PurifierError.command(.unverifiedMapping(generation: .gen2))) {
            try await session.send(.power(true))
        }
        #expect(await fake.requests(to: PurifierSession.Path.control).isEmpty)
    }

    /// Network.framework does not surface ICMP port-unreachable for UDP (checked on macOS 27),
    /// so a wrong port looks like a silent device: the deadline must still fire promptly.
    @Test func closedPortTimesOutPromptly() async throws {
        // Grab a free port, then close it so nothing listens there.
        let probe = try FakePurifier(reported: Self.auto())
        let port = try await probe.start()
        await probe.stop()

        var configuration = SessionConfiguration(host: "127.0.0.1", port: port)
        configuration.syncTimeout = .milliseconds(500)
        configuration.transport.ackTimeout = .milliseconds(100)
        let session = PurifierSession(configuration: configuration)
        defer { Task { await session.close() } }

        let start = ContinuousClock.now
        do {
            try await session.sync()
            Issue.record("expected an error")
        } catch {
            // `.connectionRefused` would be better, and is handled if the OS ever reports it.
            #expect(error == .timeout(operation: "sync", host: "127.0.0.1:\(port)", after: .milliseconds(500))
                || error == .connectionRefused(host: "127.0.0.1:\(port)"))
            #expect(error.localizedDescription.contains("127.0.0.1:\(port)"))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

/// Collects wire events from the logger callback.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WireEvent] = []

    func append(_ event: WireEvent) {
        lock.withLock { stored.append(event) }
    }

    var events: [WireEvent] {
        lock.withLock { stored }
    }
}
