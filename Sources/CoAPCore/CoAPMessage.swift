/// A CoAP message as defined by RFC 7252 §3.
///
/// This is a plain value type: it has no knowledge of sockets, retransmission or
/// exchanges. Encoding and decoding are pure functions (see `CoAPCodec.swift`) so
/// they can be tested byte for byte.
///
/// ```
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |Ver| T |  TKL  |      Code     |          Message ID           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Token (if any, TKL bytes) ...
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options (if any) ...
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |1 1 1 1 1 1 1 1|    Payload (if any) ...
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
public struct CoAPMessage: Sendable, Hashable {
    /// The protocol version. RFC 7252 defines only version 1.
    public static let version: UInt8 = 1
    /// Tokens are 0–8 bytes long (RFC 7252 §3; lengths 9–15 are reserved).
    public static let maxTokenLength = 8

    public var type: MessageType
    public var code: Code
    public var messageID: UInt16
    public var token: [UInt8]
    /// Options in the order they were added. Encoding sorts them by number (stable,
    /// so repeated options such as Uri-Path keep their relative order).
    public var options: [CoAPOption]
    public var payload: [UInt8]

    public init(
        type: MessageType,
        code: Code,
        messageID: UInt16,
        token: [UInt8] = [],
        options: [CoAPOption] = [],
        payload: [UInt8] = []
    ) {
        self.type = type
        self.code = code
        self.messageID = messageID
        self.token = token
        self.options = options
        self.payload = payload
    }
}

// MARK: - Message type

public extension CoAPMessage {
    /// The 2-bit message type (RFC 7252 §4.2–4.3).
    enum MessageType: UInt8, Sendable, CaseIterable, CustomStringConvertible {
        /// Confirmable: the receiver must ACK or RST; the sender retransmits until it does.
        case confirmable = 0
        /// Non-confirmable: fire and forget.
        case nonConfirmable = 1
        /// Acknowledgement of a confirmable message, possibly carrying a piggybacked response.
        case acknowledgement = 2
        /// Reset: "I received your message but can't process it" (also cancels observations).
        case reset = 3

        public var description: String {
            switch self {
            case .confirmable: "CON"
            case .nonConfirmable: "NON"
            case .acknowledgement: "ACK"
            case .reset: "RST"
            }
        }
    }
}

// MARK: - Code

public extension CoAPMessage {
    /// An 8-bit code split into a 3-bit class and a 5-bit detail, written `c.dd`.
    struct Code: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
        public var rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Creates a code from its class and detail, e.g. `Code(2, 5)` for 2.05 Content.
        public init(_ codeClass: UInt8, _ detail: UInt8) {
            precondition(codeClass < 8 && detail < 32, "CoAP code out of range: \(codeClass).\(detail)")
            rawValue = (codeClass << 5) | detail
        }

        public var codeClass: UInt8 {
            rawValue >> 5
        }

        public var detail: UInt8 {
            rawValue & 0x1F
        }

        public var isEmpty: Bool {
            rawValue == 0
        }

        public var isRequest: Bool {
            codeClass == 0 && detail != 0
        }

        public var isResponse: Bool {
            codeClass >= 2
        }

        public var isSuccess: Bool {
            codeClass == 2
        }

        public var description: String {
            let detailText = detail < 10 ? "0\(detail)" : "\(detail)"
            let base = "\(codeClass).\(detailText)"
            return name.map { "\(base) \($0)" } ?? base
        }

        private var name: String? {
            switch self {
            case .empty: "Empty"
            case .get: "GET"
            case .post: "POST"
            case .put: "PUT"
            case .delete: "DELETE"
            case .created: "Created"
            case .deleted: "Deleted"
            case .valid: "Valid"
            case .changed: "Changed"
            case .content: "Content"
            case .badRequest: "Bad Request"
            case .unauthorized: "Unauthorized"
            case .badOption: "Bad Option"
            case .forbidden: "Forbidden"
            case .notFound: "Not Found"
            case .methodNotAllowed: "Method Not Allowed"
            case .internalServerError: "Internal Server Error"
            case .serviceUnavailable: "Service Unavailable"
            default: nil
            }
        }

        public static let empty = Code(0, 0)
        public static let get = Code(0, 1)
        public static let post = Code(0, 2)
        public static let put = Code(0, 3)
        public static let delete = Code(0, 4)

        public static let created = Code(2, 1)
        public static let deleted = Code(2, 2)
        public static let valid = Code(2, 3)
        public static let changed = Code(2, 4)
        public static let content = Code(2, 5)

        public static let badRequest = Code(4, 0)
        public static let unauthorized = Code(4, 1)
        public static let badOption = Code(4, 2)
        public static let forbidden = Code(4, 3)
        public static let notFound = Code(4, 4)
        public static let methodNotAllowed = Code(4, 5)

        public static let internalServerError = Code(5, 0)
        public static let serviceUnavailable = Code(5, 3)
    }
}

// MARK: - Convenience accessors

public extension CoAPMessage {
    /// An Empty message (code 0.00): used for bare ACKs, RSTs and CoAP pings.
    static func empty(type: MessageType, messageID: UInt16) -> CoAPMessage {
        CoAPMessage(type: type, code: .empty, messageID: messageID)
    }

    /// The Uri-Path segments joined with `/`, with a leading slash (e.g. `/sys/dev/sync`).
    var uriPath: String {
        "/" + options(.uriPath).map { String(decoding: $0.value, as: UTF8.self) }.joined(separator: "/")
    }

    /// Replaces all Uri-Path options with the segments of `path` (empty segments are dropped).
    mutating func setURIPath(_ path: String) {
        options.removeAll { $0.number == .uriPath }
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            options.append(CoAPOption(.uriPath, string: String(segment)))
        }
    }

    /// The Observe option value, if present (RFC 7641). In a GET, 0 registers and 1 deregisters;
    /// in a notification it is a 24-bit sequence number.
    var observe: UInt32? {
        get { options(.observe).first?.uintValue }
        set { setUInt(.observe, newValue) }
    }

    /// Max-Age in seconds (RFC 7252 §5.10.5). Absent means the default of 60 s.
    var maxAge: UInt32? {
        get { options(.maxAge).first?.uintValue }
        set { setUInt(.maxAge, newValue) }
    }

    var contentFormat: UInt32? {
        get { options(.contentFormat).first?.uintValue }
        set { setUInt(.contentFormat, newValue) }
    }

    func options(_ number: CoAPOption.Number) -> [CoAPOption] {
        options.filter { $0.number == number }
    }

    private mutating func setUInt(_ number: CoAPOption.Number, _ value: UInt32?) {
        options.removeAll { $0.number == number }
        if let value {
            options.append(CoAPOption(number, uint: value))
        }
    }
}
