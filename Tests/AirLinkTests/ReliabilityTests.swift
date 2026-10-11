import Testing
@testable import AirLink

struct ReliabilityTests {
    @Test func backoffCeilingDoublesToCap() {
        var backoff = Backoff()
        var ceilings: [Duration] = []
        for _ in 0 ..< 9 {
            ceilings.append(backoff.currentCeiling)
            _ = backoff.nextDelay()
        }
        #expect(ceilings == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
        backoff.reset()
        #expect(backoff.currentCeiling == .seconds(1))
    }

    @Test func backoffDelaysAreJitteredWithinCeiling() {
        var backoff = Backoff()
        for _ in 0 ..< 50 {
            let ceiling = backoff.currentCeiling
            let delay = backoff.nextDelay()
            #expect(delay >= .zero && delay <= ceiling)
        }
    }

    @Test(arguments: [
        (UInt32?.none, Duration.seconds(180)),
        (60, .seconds(180)),
        (30, .seconds(180)),
        (120, .seconds(360)),
    ])
    func watchdogLimit(maxAge: UInt32?, limit: Duration) {
        #expect(ObserveWatchdog.silenceLimit(maxAge: maxAge) == limit)
    }

    @Test func errorsArePhrasedForHumans() {
        let timeout = PurifierError.timeout(operation: "sync", host: "192.168.1.9:5683", after: .seconds(4))
        #expect(timeout.localizedDescription.contains("192.168.1.9:5683"))
        #expect(timeout.localizedDescription.contains("4 s"))
        #expect(PurifierError.unreachable(host: "h:1", detail: "x").localizedDescription.contains("Local Network"))
    }
}
