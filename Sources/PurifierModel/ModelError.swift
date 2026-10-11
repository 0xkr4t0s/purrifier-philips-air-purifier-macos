/// Errors raised while interpreting device JSON or building commands.
public enum ModelError: Error, Sendable, Hashable, CustomStringConvertible {
    case documentTooLarge(Int)
    case invalidJSON(String)
    /// The decrypted status had no `state.reported` object.
    case missingReportedState
    /// None of the three known key schemes matched the status keys.
    case unknownGeneration(sampleKeys: [String])

    public var description: String {
        switch self {
        case let .documentTooLarge(size):
            "device JSON is \(size) bytes, over the \(JSONValue.maxDocumentBytes)-byte limit"
        case let .invalidJSON(detail):
            "device sent invalid JSON: \(detail)"
        case .missingReportedState:
            "status JSON has no state.reported object"
        case let .unknownGeneration(keys):
            "unrecognised status key scheme (keys: \(keys.joined(separator: ", ")))"
        }
    }
}

/// Errors raised when a command can't be translated for a device.
public enum CommandError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The command has no mapping for this key generation.
    case unsupported(command: String, generation: KeyGeneration)
    /// The mapping exists but its value literals have not been verified on hardware.
    case unverifiedMapping(generation: KeyGeneration)
    /// `set` was given a key the protocol envelope reserves (`CommandType`, `DeviceId`, `EnduserId`).
    case reservedKey(String)
    case invalidAssignment(String)
    case emptyCommand

    public var description: String {
        switch self {
        case let .unsupported(command, generation):
            "\(command) is not supported on \(generation.displayName) devices"
        case let .unverifiedMapping(generation):
            "writes for \(generation.displayName) devices are not verified on hardware yet; "
                + "pass --allow-unverified to send them anyway"
        case let .reservedKey(key):
            "\"\(key)\" is part of the control envelope and can't be set directly"
        case let .invalidAssignment(text):
            "expected KEY=VALUE, got \"\(text)\""
        case .emptyCommand:
            "nothing to set"
        }
    }
}
