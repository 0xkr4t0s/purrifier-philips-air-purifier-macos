/// The client key / counter used by the encrypted CoAP protocol.
///
/// `POST /sys/dev/sync` returns it as hex text. The client increments it **before** every
/// encrypted send and puts the incremented value at the start of the frame, where it also
/// selects the AES key and IV. Frames sent *by the device* carry the device's own counter,
/// and decryption uses whatever counter the frame carries.
///
/// The value is stored exactly as received, because the key derivation hashes the ASCII
/// text: `"0A"` and `"0a"` produce different keys.
public struct PhilipsCounter: Sendable, Hashable, CustomStringConvertible {
    /// The counter as ASCII hex text, exactly as it goes on the wire.
    public let hex: String

    /// Wraps a counter string, rejecting empty strings, non-hex characters and values wider
    /// than 64 bits. Width is *not* checked here; that is the job of `CounterWidthPolicy`.
    public init(hex: String) throws(PhilipsCryptoError) {
        guard !hex.isEmpty, hex.utf8.count <= 16, UInt64(hex, radix: 16) != nil else {
            throw .invalidCounter(hex)
        }
        self.hex = hex
    }

    /// The numeric value. Always succeeds for a validated counter.
    public var value: UInt64 {
        UInt64(hex, radix: 16) ?? 0
    }

    public var description: String {
        hex
    }

    /// Returns the next counter under `policy`.
    public func incremented(policy: CounterWidthPolicy = .default) throws(PhilipsCryptoError) -> PhilipsCounter {
        switch policy {
        case .fixedWidthWrapping:
            guard hex.utf8.count == 8 else { throw .unexpectedCounterWidth(hex) }
            let next = UInt32(truncatingIfNeeded: value &+ 1)
            return PhilipsCounter(unchecked: Self.uppercaseHex(UInt64(next), width: 8))
        case .fixedWidthStrict:
            guard hex.utf8.count == 8 else { throw .unexpectedCounterWidth(hex) }
            guard value < 0xFFFF_FFFF else { throw .counterExhausted }
            return PhilipsCounter(unchecked: Self.uppercaseHex(value + 1, width: 8))
        case .unpadded:
            guard value < UInt64.max else { throw .counterExhausted }
            return PhilipsCounter(unchecked: Self.uppercaseHex(value + 1, width: 0))
        }
    }

    /// Advances in place and returns the new value, the way an encrypting sender does.
    public mutating func advance(policy: CounterWidthPolicy = .default) throws(PhilipsCryptoError) -> PhilipsCounter {
        self = try incremented(policy: policy)
        return self
    }

    private init(unchecked hex: String) {
        self.hex = hex
    }

    static func uppercaseHex(_ value: UInt64, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return digits.utf8.count >= width ? digits : String(repeating: "0", count: width - digits.utf8.count) + digits
    }
}

/// How the counter is formatted after an increment. The two Python references disagree,
/// so the choice is explicit and tested (see `Tests/Fixtures/crypto_vectors.json`).
public enum CounterWidthPolicy: Sendable, Hashable, CaseIterable {
    /// Always 8 uppercase hex digits, zero-padded; `FFFFFFFF` wraps to `00000000`.
    /// This is what aioairctrl 0.3.1 does (`(n + 1) % 2**32`, `to_bytes(4)`), and it keeps the
    /// frame layout the decrypt side assumes (exactly 8 counter characters).
    ///
    /// TODO(verify): no one has observed what a real device does at the wrap-around.
    case fixedWidthWrapping

    /// Always 8 digits, but throws `.counterExhausted` instead of wrapping, so the caller can
    /// resync to get a fresh counter. The conservative choice if wrap-around turns out to break.
    case fixedWidthStrict

    /// py-air-control's `"{:x}".format(n + 1).upper()`: no zero padding, so `"0000000A"`
    /// becomes `"B"` and `"FFFFFFFF"` becomes `"100000000"`. Such frames break the 8-character
    /// framing on the receive side. Only for cross-checking against that reference.
    case unpadded

    /// Matches aioairctrl, the reference the Home Assistant integration uses today.
    public static let `default`: CounterWidthPolicy = .fixedWidthWrapping
}
