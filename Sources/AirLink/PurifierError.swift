import CoAPCore
import Foundation
import PhilipsCrypto
import PurifierModel

/// Errors from `PurifierSession`, phrased for the person at the keyboard. Each carries
/// enough context (host, operation) to act on without a debugger.
public enum PurifierError: Error, Sendable, Hashable {
    case timeout(operation: String, host: String, after: Duration)
    case connectionRefused(host: String)
    case unreachable(host: String, detail: String)
    case reset(operation: String)
    case unexpectedResponse(operation: String, code: CoAPMessage.Code, body: String)
    case invalidSyncResponse(String)
    case crypto(operation: String, PhilipsCryptoError)
    case model(ModelError)
    case command(CommandError)
    /// The device answered a control request with something other than success.
    case controlRejected(response: String)
    /// The status stream ended before the first notification.
    case observationEnded
    case closed
    case transport(String)

    /// Whether "resync, then retry once" might help.
    var isRetryable: Bool {
        switch self {
        case .timeout, .reset, .unexpectedResponse, .crypto, .controlRejected, .observationEnded, .invalidSyncResponse:
            true
        case .model(.invalidJSON), .model(.missingReportedState):
            true // garbage after a successful decrypt suggests a wrong key, i.e. a stale counter
        case .connectionRefused, .unreachable, .model, .command, .closed, .transport:
            false
        }
    }
}

extension PurifierError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .timeout(operation, host, after):
            "No reply from the purifier at \(host) within \(after.formattedSeconds) (\(operation)). "
                + "Check the address and that the purifier is on Wi-Fi. If it is, the purifier may be "
                + "wedged — a known firmware bug — so power-cycle it (unplug for 10 seconds)."
        case let .connectionRefused(host):
            "\(host) refused the connection: something is there, but nothing is listening on the CoAP port. "
                + "Is this the purifier's address, and is the port right (default 5683)?"
        case let .unreachable(host, detail):
            "Can't reach \(host) (\(detail)). On macOS 15 and later, check that Local Network access is allowed "
                + "(System Settings → Privacy & Security → Local Network)."
        case let .reset(operation):
            "The purifier rejected the \(operation) request (CoAP reset)."
        case let .unexpectedResponse(operation, code, body):
            "Unexpected \(code) response to \(operation)" + (body.isEmpty ? "." : ": \(body)")
        case let .invalidSyncResponse(text):
            "The purifier's sync reply \"\(text)\" is not an 8-digit hex counter."
        case let .crypto(operation, error):
            "Couldn't decrypt the \(operation) reply: \(error)."
        case let .model(error):
            "Unexpected status data: \(error)."
        case let .command(error):
            "\(error)."
        case let .controlRejected(response):
            "The purifier refused the command after a resync (reply: \(response)). "
                + "If this keeps happening, power-cycle the purifier."
        case .observationEnded:
            "The purifier ended the status subscription without sending a status."
        case .closed:
            "The session is closed."
        case let .transport(detail):
            "Network error: \(detail)."
        }
    }
}

extension Duration {
    /// "4 s", "0.5 s".
    var formattedSeconds: String {
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }
}
