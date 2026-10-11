import PurifierModel
import Testing

struct CommandTests {
    @Test func gen3ModeWritesPowerAndMode() throws {
        let values = try Command.mode(.sleep).desiredValues(for: .gen3)
        #expect(values == [DesiredValue("D03102", 1), DesiredValue("D0310C", 17)])
    }

    @Test(arguments: [(PurifierMode.auto, JSONValue.int(0)), (.sleep, 17), (.turbo, 18)])
    func gen3ModeValues(mode: PurifierMode, value: JSONValue) throws {
        #expect(try Command.mode(mode).desiredValues(for: .gen3).last?.value == value)
    }

    @Test func gen3Power() throws {
        #expect(try Command.power(true).desiredValues(for: .gen3) == [DesiredValue("D03102", 1)])
        #expect(try Command.power(false).desiredValues(for: .gen3) == [DesiredValue("D03102", 0)])
    }

    @Test func gen2RequiresOptIn() throws {
        #expect(throws: CommandError.unverifiedMapping(generation: .gen2)) {
            try Command.power(true).desiredValues(for: .gen2)
        }
        let values = try Command.mode(.turbo).desiredValues(for: .gen2, allowUnverified: true)
        #expect(values == [DesiredValue("D03-02", "ON"), DesiredValue("D03-12", "Turbo")])
    }

    @Test func gen1ModeIsUnsupported() {
        #expect(throws: CommandError.unsupported(command: "mode sleep", generation: .gen1)) {
            try Command.mode(.sleep).desiredValues(for: .gen1, allowUnverified: true)
        }
    }

    @Test func rawPassesThroughInOrder() throws {
        let raw: [DesiredValue] = [DesiredValue("D0310C", 18), DesiredValue("D03102", 1)]
        #expect(try Command.raw(raw).desiredValues(for: .gen3) == raw)
        #expect(throws: CommandError.emptyCommand) { try Command.raw([]).desiredValues(for: .gen3) }
        #expect(throws: CommandError.reservedKey("DeviceId")) {
            try Command.raw([DesiredValue("DeviceId", "x")]).desiredValues(for: .gen3)
        }
    }

    // MARK: Assignment parsing (aioairctrl `set` semantics)

    @Test(arguments: [
        ("D0310C=18", true, DesiredValue("D0310C", 18)),
        ("D0310C=18", false, DesiredValue("D0310C", "18")),
        ("D03-02=ON", false, DesiredValue("D03-02", "ON")),
        ("cl=true", true, DesiredValue("cl", true)),
        ("cl=false", false, DesiredValue("cl", false)),
        ("name=a=b", false, DesiredValue("name", "a=b")),
        ("x=", false, DesiredValue("x", "")),
        ("x=-5", true, DesiredValue("x", -5)),
    ])
    func parsesAssignments(text: String, asInteger: Bool, expected: DesiredValue) throws {
        #expect(try DesiredValue.parse(assignment: text, asInteger: asInteger) == expected)
    }

    @Test(arguments: [("D0310C", false), ("=1", false), ("D0310C=abc", true), ("x=1.5", true)])
    func rejectsBadAssignments(text: String, asInteger: Bool) {
        #expect(throws: CommandError.invalidAssignment(text)) {
            try DesiredValue.parse(assignment: text, asInteger: asInteger)
        }
    }

    // MARK: Envelope

    @Test func controlJSONMatchesPythonJsonDumps() {
        // Exactly what aioairctrl's json.dumps produces for `set -I D0310C=18`.
        #expect(ControlRequest.json([DesiredValue("D0310C", 18)])
            == #"{"state": {"desired": {"CommandType": "app", "DeviceId": "", "EnduserId": "", "D0310C": 18}}}"#)
    }

    @Test func controlResponse() {
        #expect(ControlRequest.isSuccess(Array(#"{"status":"success"}"#.utf8)))
        #expect(ControlRequest.isSuccess(Array(#"{"status": "success"}"#.utf8)))
        #expect(!ControlRequest.isSuccess(Array(#"{"status":"failed"}"#.utf8)))
        #expect(!ControlRequest.isSuccess(Array("".utf8)))
        #expect(!ControlRequest.isSuccess(Array("success".utf8)))
    }
}

struct JSONValueTests {
    @Test func pythonStyleSerialisation() {
        let value: JSONValue = .object([
            "b": .array([1, 2.5, "x", nil, true]),
            "a": "é\"\n\u{7F}😀",
        ])
        // Same as Python: json.dumps({"a": "é\"\n\x7f😀", "b": [1, 2.5, "x", None, True]}, sort_keys=True)
        #expect(value.pythonJSON == #"{"a": "\u00e9\"\n\u007f\ud83d\ude00", "b": [1, 2.5, "x", null, true]}"#)
    }

    @Test func floatsLookLikePython() {
        #expect(JSONValue.double(1).pythonJSON == "1.0")
        #expect(JSONValue.double(-0.5).pythonJSON == "-0.5")
    }

    @Test func parseKeepsIntegersAsIntegers() throws {
        let value = try JSONValue.parse(Array(#"{"a": 17, "b": 1.5, "c": true, "d": "1"}"#.utf8))
        #expect(value == .object(["a": .int(17), "b": .double(1.5), "c": .bool(true), "d": .string("1")]))
    }

    @Test func parseRejectsOversizedDocuments() {
        let big = [UInt8](repeating: 0x20, count: JSONValue.maxDocumentBytes + 1)
        #expect(throws: ModelError.documentTooLarge(big.count)) { try JSONValue.parse(big) }
    }

    @Test func statusDocumentUnwrapsReported() throws {
        let reported = try StatusDocument.reported(from: Array(#"{"state":{"reported":{"D03102":1}}}"#.utf8))
        #expect(reported == ["D03102": 1])
        #expect(throws: ModelError.missingReportedState) {
            try StatusDocument.reported(from: Array(#"{"state":{}}"#.utf8))
        }
    }
}
