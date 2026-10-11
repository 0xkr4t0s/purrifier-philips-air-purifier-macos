/// One key/value pair in the `desired` object of a control request. Order is preserved,
/// because aioairctrl preserves it and we want byte-identical frames.
public struct DesiredValue: Sendable, Hashable, CustomStringConvertible {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }

    public var description: String { "\(key)=\(value.pythonJSON)" }

    /// Parses `KEY=VALUE` with aioairctrl's `set` semantics: `true`/`false` become booleans,
    /// everything else is a string unless `asInteger` (`-I`) is set.
    public static func parse(assignment: String, asInteger: Bool) throws(CommandError) -> DesiredValue {
        guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
            throw .invalidAssignment(assignment)
        }
        let key = String(assignment[..<equals])
        let text = String(assignment[assignment.index(after: equals)...])
        switch text {
        case "true": return DesiredValue(key, true)
        case "false": return DesiredValue(key, false)
        default:
            guard asInteger else { return DesiredValue(key, .string(text)) }
            guard let number = Int64(text) else { throw .invalidAssignment(assignment) }
            return DesiredValue(key, .int(number))
        }
    }
}

/// A high-level command, translated per key generation.
public enum Command: Sendable, Hashable {
    case power(Bool)
    /// Sets the mode and turns the device on, as the Home Assistant integration does.
    case mode(PurifierMode)
    /// Raw key/value pairs, sent as given (`purrctl set`).
    case raw([DesiredValue])

    /// The `desired` values to send to a device of `generation`.
    ///
    /// Callers must know the generation first: writing gen1 keys to a gen3 unit is ignored
    /// or refused, so `PurifierSession` reads status before its first write.
    public func desiredValues(
        for generation: KeyGeneration,
        allowUnverified: Bool = false
    ) throws(CommandError) -> [DesiredValue] {
        let map = KeyMap.forGeneration(generation)
        switch self {
        case let .raw(values):
            guard !values.isEmpty else { throw .emptyCommand }
            if let reserved = values.first(where: { ControlRequest.envelopeKeys.contains($0.key) }) {
                throw .reservedKey(reserved.key)
            }
            return values
        case let .power(on):
            guard map.writesVerified || allowUnverified else { throw .unverifiedMapping(generation: generation) }
            return [DesiredValue(map.power, on ? map.powerOn : map.powerOff)]
        case let .mode(mode):
            guard let modeKey = map.mode, let value = map.modeValues[mode] else {
                throw .unsupported(command: "mode \(mode.rawValue)", generation: generation)
            }
            guard map.writesVerified || allowUnverified else { throw .unverifiedMapping(generation: generation) }
            return [DesiredValue(map.power, map.powerOn), DesiredValue(modeKey, value)]
        }
    }
}

/// The control request envelope and response check.
public enum ControlRequest {
    static let envelopeKeys: Set<String> = ["CommandType", "DeviceId", "EnduserId"]

    /// `{"state": {"desired": {"CommandType": "app", "DeviceId": "", "EnduserId": "", <values>}}}`,
    /// formatted exactly like aioairctrl's `json.dumps(...)`.
    public static func json(_ values: [DesiredValue]) -> String {
        var desired: [(key: String, value: JSONValue)] = [
            ("CommandType", "app"), ("DeviceId", ""), ("EnduserId", ""),
        ]
        desired += values.map { ($0.key, $0.value) }
        var out = "{\"state\": {\"desired\": "
        JSONValue.writeObject(desired, into: &out)
        out += "}}"
        return out
    }

    /// Whether a (plain-text) control response means success.
    ///
    /// py-air-control requires the exact text `{"status":"success"}`; aioairctrl parses the JSON
    /// and checks `status == "success"`. We accept the exact text, or any JSON object whose
    /// `status` is `"success"` (so whitespace differences don't trigger a needless resync).
    public static func isSuccess(_ payload: some Collection<UInt8>) -> Bool {
        if Array(payload) == Array(#"{"status":"success"}"#.utf8) { return true }
        return (try? JSONValue.parse(payload))?.objectValue?["status"] == "success"
    }
}
