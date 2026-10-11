import CoAPCore

/// Low-level transport failures. `PurifierSession` wraps these in `PurifierError`, which
/// adds the host, the operation and advice for the user.
public enum TransportError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidEndpoint(String)
    /// No usable route, or Network.framework never became ready (Local Network permission?).
    case unreachable(String)
    /// ICMP port unreachable: the host is up but nothing listens on the port.
    case connectionRefused
    case sendFailed(String)
    case receiveFailed(String)
    /// No response before the deadline, after all retransmissions.
    case timeout
    /// The peer answered with RST: it received the message but won't process it.
    case reset
    case encodingFailed(CoAPEncodingError)
    case closed

    public var description: String {
        switch self {
        case let .invalidEndpoint(detail): "invalid address: \(detail)"
        case let .unreachable(detail): "network unreachable (\(detail))"
        case .connectionRefused: "connection refused (ICMP port unreachable)"
        case let .sendFailed(detail): "send failed: \(detail)"
        case let .receiveFailed(detail): "receive failed: \(detail)"
        case .timeout: "timed out"
        case .reset: "the device answered with a CoAP reset (RST)"
        case let .encodingFailed(error): "could not encode CoAP message: \(error)"
        case .closed: "connection closed"
        }
    }
}
