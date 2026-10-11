/// Uppercase hex encoding as used throughout the frame format.
/// (A copy of `CoAPCore.Hex`, kept separate so the crypto module has no dependencies.)
enum HexText {
    private static let digits = Array("0123456789ABCDEF".utf8)

    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var ascii: [UInt8] = []
        for byte in bytes {
            ascii.append(digits[Int(byte >> 4)])
            ascii.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: ascii, as: UTF8.self)
    }

    /// Returns `nil` for odd lengths or non-hex characters. Accepts either case.
    static func decode(_ text: String) -> [UInt8]? {
        let ascii = Array(text.utf8)
        guard ascii.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(ascii.count / 2)
        for index in stride(from: 0, to: ascii.count, by: 2) {
            guard let high = nibble(ascii[index]), let low = nibble(ascii[index + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case 0x30 ... 0x39: char - 0x30
        case 0x41 ... 0x46: char - 0x41 + 10
        case 0x61 ... 0x66: char - 0x61 + 10
        default: nil
        }
    }
}
