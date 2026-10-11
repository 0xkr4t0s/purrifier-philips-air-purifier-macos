import ArgumentParser
import FakePurifier
import Foundation
import PurifierModel

/// Runs the simulator on a UDP port so `purrctl` (or aioairctrl) can be pointed at it:
///
///     swift run fake-purifier --port 5683
///     swift run purrctl --host 127.0.0.1 status
@main
struct FakePurifierCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fake-purifier",
        abstract: "Simulate a Philips Air+ purifier (encrypted CoAP device side) for testing."
    )

    @Option(help: "UDP port to listen on (0 = pick a free one).")
    var port: UInt16 = 5683

    @Option(help: "JSON file with a state.reported object to serve. Default: built-in AC0850/11 in Auto.")
    var fixture: String?

    @Flag(help: "Listen on all interfaces instead of loopback only.")
    var listenAll = false

    @Option(help: "Answer the next N control requests with {\"status\":\"failed\"}.")
    var failControls = 0

    @Option(help: "Corrupt the digest of the next N status frames.")
    var corruptDigests = 0

    @Option(help: "Drop the next N sync requests.")
    var dropSync = 0

    @Flag(help: "Never answer status requests (push-only firmware).")
    var pushOnly = false

    @Flag(help: "Ignore everything (a wedged device).")
    var wedged = false

    func run() async throws {
        let reported: [String: JSONValue]
        if let fixture {
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
            guard let object = try JSONValue.parse(Array(data)).objectValue else {
                throw ValidationError("\(fixture) is not a JSON object")
            }
            reported = object["state"]?.objectValue?["reported"]?.objectValue ?? object
        } else {
            reported = Self.defaultState
        }

        var behavior = FakePurifier.Behavior()
        behavior.loopbackOnly = !listenAll
        var faults = FakePurifier.Faults()
        faults.failControls = failControls
        faults.corruptStatusDigests = corruptDigests
        faults.dropRequests["/sys/dev/sync"] = dropSync
        faults.ignoreStatusRequests = pushOnly
        faults.wedged = wedged

        let fake = FakePurifier(reported: reported, behavior: behavior, faults: faults)
        let bound = try await fake.start(port: port)
        print("fake-purifier listening on \(listenAll ? "*" : "127.0.0.1"):\(bound) — Ctrl-C to stop")

        var seen = 0
        while true {
            try await Task.sleep(for: .milliseconds(200))
            let requests = await fake.requests
            for request in requests.dropFirst(seen) {
                print("\(request.type) \(request.code) \(request.path) mid=\(request.messageID) peer=\(request.peer)")
            }
            seen = requests.count
        }
    }

    /// The AC0850/11 "Auto" dump from kongo09/philips-airpurifier-coap#139, trimmed.
    static let defaultState: [String: JSONValue] = [
        "D01S03": "Bedroom", "D01S05": "AC0850/11", "D01S12": "0.1.3",
        "WifiVersion": "AWS_Philips_AIR_Combo@1.2", "DeviceId": "0000000000000000000000000000fake",
        "rssi": -70, "D03102": 1, "D0310A": 2, "D0310C": 0, "D0310D": 1, "D03120": 1, "D03221": 3,
        "D0312A": 1, "D03134": 1, "D03240": 0, "D05408": 4800, "D0540E": 4788,
    ]
}
