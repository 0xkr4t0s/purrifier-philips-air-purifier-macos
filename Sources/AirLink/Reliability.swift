import Foundation

// Reliability scaffolding for milestone M2 (see plan.md, "Reliability strategy").
// The pieces that are pure logic are implemented and tested now; wiring them into a
// self-healing session loop is M2 work and marked TODO(M2).

/// Where a long-lived session is in its lifecycle.
///
/// ```
/// idle → syncing → observing ⇄ degraded → resyncing → (backoff) → syncing
/// ```
public enum SessionPhase: Sendable, Hashable, CustomStringConvertible {
    case idle
    case syncing
    /// Synced; one-shot requests work. (M1 sessions stay here between calls.)
    case ready
    case observing
    /// Something went wrong (timeout, digest mismatch, silence); a resync is pending.
    case degraded(reason: String)
    case resyncing(attempt: Int)
    case closed

    public var description: String {
        switch self {
        case .idle: "idle"
        case .syncing: "syncing"
        case .ready: "ready"
        case .observing: "observing"
        case let .degraded(reason): "degraded (\(reason))"
        case let .resyncing(attempt): "resyncing (attempt \(attempt))"
        case .closed: "closed"
        }
    }
}

/// Exponential backoff with full jitter: 1 s, 2 s, 4 s … capped at 60 s, reset after
/// 5 minutes of health.
public struct Backoff: Sendable, Hashable {
    public var base: Duration = .seconds(1)
    public var cap: Duration = .seconds(60)
    public var resetAfterHealthy: Duration = .seconds(300)
    public private(set) var attempt = 0

    public init() {}

    /// The upper bound for the next delay, before jitter: `min(cap, base × 2^attempt)`.
    public var currentCeiling: Duration {
        let factor = 1 << min(attempt, 30)
        let raw = base * factor
        return raw < cap ? raw : cap
    }

    /// Returns a delay uniformly drawn from `0...currentCeiling` and advances the attempt count.
    public mutating func nextDelay(using generator: inout some RandomNumberGenerator) -> Duration {
        let ceiling = currentCeiling
        attempt += 1
        let fraction = Double.random(in: 0 ... 1, using: &generator)
        return ceiling * fraction
    }

    public mutating func nextDelay() -> Duration {
        var generator = SystemRandomNumberGenerator()
        return nextDelay(using: &generator)
    }

    /// Call after a period of health at least `resetAfterHealthy` long.
    public mutating func reset() {
        attempt = 0
    }
}

/// How long an observation may stay silent before the session treats it as dead:
/// `max(3 × Max-Age, 180 s)`. HA PR #388 rebuilds the client after 3 × 60 s.
public enum ObserveWatchdog {
    public static let minimumSilence: Duration = .seconds(180)

    public static func silenceLimit(maxAge: UInt32?) -> Duration {
        let maxAge = Duration.seconds(Int(maxAge ?? 60))
        let limit = maxAge * 3
        return limit > minimumSilence ? limit : minimumSilence
    }
}

/// Flags learned about a device's behaviour at runtime.
public struct DeviceQuirks: Sendable, Hashable {
    /// The device answers sync but never answers an Observe registration until it next
    /// pushes on its own (seen on `AWS_Philips_AIR_Combo@86`). The UI should then update
    /// optimistically after a successful control.
    ///
    /// TODO(M2): set when an observe registration times out while sync keeps working.
    public var pushOnly = false

    public init() {}
}

// TODO(M2): a `SessionSupervisor` that owns a `PurifierSession`, drives `SessionPhase`,
// applies `Backoff` between resyncs, restarts the observation when `ObserveWatchdog` fires,
// and listens to `NWPathMonitor` (network changes) and, in the app,
// `NSWorkspace.didWakeNotification` to resync immediately.
