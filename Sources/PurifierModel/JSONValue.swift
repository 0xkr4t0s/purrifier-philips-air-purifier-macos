import Foundation

/// A JSON value. Integers and floating-point numbers are kept apart so that values read from
/// a device are written back exactly (`17` stays `17`, never `17.0`).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Typed access

extension JSONValue {
    /// The value as an integer: an `int`, or a `double` with no fractional part.
    public var intValue: Int? {
        switch self {
        case let .int(value): Int(exactly: value)
        case let .double(value): Int(exactly: value)
        default: nil
        }
    }

    /// Like `intValue`, but also accepts decimal strings such as `"1"` (gen1 devices send those).
    public var looseIntValue: Int? {
        if let intValue { return intValue }
        if case let .string(text) = self { return Int(text) }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }
}

extension JSONValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByNilLiteral
{
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral _: ()) { self = .null }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Parsing with bounds

extension JSONValue {
    /// Upper bound on any JSON document accepted from the network. A full AC0850 status is
    /// about 1 KB; anything near this size is not a purifier talking.
    public static let maxDocumentBytes = 64 * 1024

    /// Parses untrusted bytes, refusing oversized documents before any work is done.
    public static func parse(_ bytes: some Collection<UInt8>) throws(ModelError) -> JSONValue {
        guard bytes.count <= maxDocumentBytes else { throw .documentTooLarge(bytes.count) }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(bytes))
        } catch {
            throw .invalidJSON(String(describing: error))
        }
    }
}

// MARK: - Python-compatible serialisation

extension JSONValue {
    /// Serialises the way Python's `json.dumps` does with default arguments: `", "` and
    /// `": "` separators and `ensure_ascii=True`. Object keys are sorted so output is stable.
    ///
    /// Control frames built this way are byte-identical to aioairctrl's for the same counter.
    public var pythonJSON: String {
        var out = ""
        write(into: &out)
        return out
    }

    func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case let .bool(value):
            out += value ? "true" : "false"
        case let .int(value):
            out += String(value)
        case let .double(value):
            out += Self.pythonFloat(value)
        case let .string(value):
            Self.writeString(value, into: &out)
        case let .array(values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += ", " }
                value.write(into: &out)
            }
            out += "]"
        case let .object(members):
            Self.writeObject(members.sorted { $0.key < $1.key }, into: &out)
        }
    }

    /// Writes an object with members in the given order.
    static func writeObject(_ members: [(key: String, value: JSONValue)], into out: inout String) {
        out += "{"
        for (index, member) in members.enumerated() {
            if index > 0 { out += ", " }
            writeString(member.key, into: &out)
            out += ": "
            member.value.write(into: &out)
        }
        out += "}"
    }

    /// JSON string escaping as Python does it with `ensure_ascii=True`.
    static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for unit in value.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20 ... 0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                let hex = String(unit, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            }
        }
        out += "\""
    }

    static func pythonFloat(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), abs(value) < 1e16 { return String(format: "%.1f", value) }
        return String(value) // shortest round-trip repr, like Python's
    }
}
