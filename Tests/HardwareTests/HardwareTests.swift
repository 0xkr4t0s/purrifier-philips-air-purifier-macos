import AirLink
import Foundation
import PurifierModel
import Testing

/// Hardware-in-the-loop tests against a real purifier. Skipped unless `PURRIFIER_HIL_HOST`
/// is set, so CI never touches a device. Run with `make hil IP=192.168.x.y`.
///
/// These change the device's mode and restore it afterwards. Only run them against your own unit.
enum HIL {
    static let host = ProcessInfo.processInfo.environment["PURRIFIER_HIL_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    static let port = ProcessInfo.processInfo.environment["PURRIFIER_HIL_PORT"].flatMap(UInt16.init) ?? 5683
}

@Suite(.enabled(if: HIL.host != nil, "set PURRIFIER_HIL_HOST to run hardware tests"), .serialized)
struct HardwareTests {
    static func session() throws -> PurifierSession {
        let host = try #require(HIL.host)
        return PurifierSession(configuration: SessionConfiguration(host: host, port: HIL.port))
    }

    @Test func syncReturnsEightHexDigits() async throws {
        let session = try Self.session()
        defer { Task { await session.close() } }
        let counter = try await session.sync()
        #expect(counter.hex.utf8.count == 8)
    }

    @Test func statusParses() async throws {
        let session = try Self.session()
        defer { Task { await session.close() } }
        let state = try await session.state()
        #expect(state.isOn != nil)
        print("HIL: \(state.device.model ?? "?") \(state.device.wifiVersion ?? "?") \(state.generation)")
    }

    /// M1 acceptance: set-mode changes the unit within 2 s, then restore the original mode.
    @Test func setModeTakesEffectQuickly() async throws {
        let session = try Self.session()
        defer { Task { await session.close() } }
        let before = try await session.state()
        try #require(before.isOn == true, "switch the purifier on before running this test")
        let original = try #require(before.mode)
        let target: PurifierMode = original == .sleep ? .auto : .sleep

        let start = ContinuousClock.now
        try await session.send(.mode(target))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(try await session.state().mode == target)

        try await session.send(.mode(original))
    }
}
