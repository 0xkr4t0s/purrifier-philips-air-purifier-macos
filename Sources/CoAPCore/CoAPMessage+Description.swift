extension CoAPMessage: CustomStringConvertible {
    /// A one-line summary such as `CON 0.02 POST mid=0x1A2B tok=0A0B0C0D /sys/dev/sync [8 B]`.
    /// The payload is never included, so this is safe to log.
    public var description: String {
        var parts = ["\(type)", "\(code)", "mid=0x\(Hex.encode(messageID))"]
        if !token.isEmpty {
            parts.append("tok=\(Hex.encode(token))")
        }
        if !options(.uriPath).isEmpty {
            parts.append(uriPath)
        }
        for option in options where option.number != .uriPath {
            let value = option.uintValue.map(String.init) ?? Hex.encode(option.value)
            parts.append("\(option.number)=\(value)")
        }
        if !payload.isEmpty {
            parts.append("[\(payload.count) B]")
        }
        return parts.joined(separator: " ")
    }
}

/// Uppercase hex helpers shared across the package.
public enum Hex {
    private static let digits = Array("0123456789ABCDEF".utf8)

    public static func encode(_ bytes: some Sequence<UInt8>, separator: String = "") -> String {
        var out = ""
        for (index, byte) in bytes.enumerated() {
            if index > 0 { out += separator }
            out.unicodeScalars.append(Unicode.Scalar(digits[Int(byte >> 4)]))
            out.unicodeScalars.append(Unicode.Scalar(digits[Int(byte & 0x0F)]))
        }
        return out
    }

    public static func encode(_ value: UInt16) -> String {
        encode([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Decodes hex text (either case, no separators). Returns `nil` on odd length or a non-hex character.
    public static func decode(_ text: some StringProtocol) -> [UInt8]? {
        let utf8 = Array(text.utf8)
        guard utf8.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): char - UInt8(ascii: "0")
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): char - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): char - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
