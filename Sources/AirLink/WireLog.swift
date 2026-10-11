/// Events for `--debug` output. Nothing is logged unless a logger is installed, and
/// decrypted payloads appear only in `.decrypted` events: the threat model treats them as
/// sensitive (room name, air quality, device ID).
public enum WireEvent: Sendable {
    case sent([UInt8])
    case received([UInt8])
    case decrypted(direction: Direction, json: String)
    case note(String)

    public enum Direction: String, Sendable {
        case outgoing = "→"
        case incoming = "←"
    }
}

public typealias WireLogger = @Sendable (WireEvent) -> Void
