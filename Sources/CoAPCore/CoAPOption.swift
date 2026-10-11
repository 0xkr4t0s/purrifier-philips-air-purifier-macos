/// A single CoAP option: a number plus an opaque value (RFC 7252 §3.1, §5.4).
public struct CoAPOption: Sendable, Hashable {
    /// Largest value length the 14-nibble extended form can express (268 + 65 536).
    public static let maxValueLength = 65804

    public var number: Number
    public var value: [UInt8]

    public init(_ number: Number, value: [UInt8] = []) {
        self.number = number
        self.value = value
    }

    /// A string option (UTF-8, e.g. Uri-Path).
    public init(_ number: Number, string: String) {
        self.init(number, value: Array(string.utf8))
    }

    /// A uint option, encoded big-endian in the minimum number of bytes; 0 is encoded as
    /// zero bytes (RFC 7252 §3.2). This is how aiocoap encodes `Observe: 0`.
    public init(_ number: Number, uint: UInt32) {
        var bytes: [UInt8] = []
        var remaining = uint
        while remaining > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        self.init(number, value: bytes)
    }

    /// Interprets the value as a big-endian uint. Returns `nil` if it is longer than 4 bytes.
    public var uintValue: UInt32? {
        guard value.count <= 4 else { return nil }
        return value.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public var stringValue: String {
        String(decoding: value, as: UTF8.self)
    }
}

public extension CoAPOption {
    /// An option number. Odd numbers are "critical": a receiver that doesn't understand one
    /// must reject the message (RFC 7252 §5.4.1).
    struct Number: RawRepresentable, Sendable, Hashable, Comparable, CustomStringConvertible {
        public var rawValue: UInt16

        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }

        public var isCritical: Bool {
            rawValue & 1 == 1
        }

        public static func < (lhs: Number, rhs: Number) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var description: String {
            switch self {
            case .ifMatch: "If-Match"
            case .uriHost: "Uri-Host"
            case .eTag: "ETag"
            case .ifNoneMatch: "If-None-Match"
            case .observe: "Observe"
            case .uriPort: "Uri-Port"
            case .locationPath: "Location-Path"
            case .uriPath: "Uri-Path"
            case .contentFormat: "Content-Format"
            case .maxAge: "Max-Age"
            case .uriQuery: "Uri-Query"
            case .accept: "Accept"
            case .locationQuery: "Location-Query"
            case .block2: "Block2"
            case .block1: "Block1"
            case .size2: "Size2"
            case .proxyURI: "Proxy-Uri"
            case .proxyScheme: "Proxy-Scheme"
            case .size1: "Size1"
            default: "Option(\(rawValue))"
            }
        }

        public static let ifMatch = Number(rawValue: 1)
        public static let uriHost = Number(rawValue: 3)
        public static let eTag = Number(rawValue: 4)
        public static let ifNoneMatch = Number(rawValue: 5)
        /// RFC 7641.
        public static let observe = Number(rawValue: 6)
        public static let uriPort = Number(rawValue: 7)
        public static let locationPath = Number(rawValue: 8)
        public static let uriPath = Number(rawValue: 11)
        public static let contentFormat = Number(rawValue: 12)
        public static let maxAge = Number(rawValue: 14)
        public static let uriQuery = Number(rawValue: 15)
        public static let accept = Number(rawValue: 17)
        public static let locationQuery = Number(rawValue: 20)
        /// RFC 7959.
        public static let block2 = Number(rawValue: 23)
        /// RFC 7959.
        public static let block1 = Number(rawValue: 27)
        public static let size2 = Number(rawValue: 28)
        public static let proxyURI = Number(rawValue: 35)
        public static let proxyScheme = Number(rawValue: 39)
        public static let size1 = Number(rawValue: 60)
    }
}
