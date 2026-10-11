/// The three JSON key schemes seen on Philips Air+ CoAP devices (from kongo09's
/// philips-airpurifier-coap `const.py`). The scheme follows the Wi-Fi firmware
/// (`WifiVersion`), not the model suffix: two AC0850/20 units can differ.
public enum KeyGeneration: String, Sendable, Hashable, CaseIterable, Codable {
    /// Short keys: `pwr`, `om`, `mode`, `pm25`, `iaql` (older AC2xxx/AC3xxx units).
    case gen1
    /// `D0x-yy` keys (the "AC1715 scheme"), e.g. `D03-02` power. Firmware `AWS_Philips_AIR@…`.
    case gen2
    /// `D0xxxx` keys, e.g. `D03102` power. Firmware `AWS_Philips_AIR_Combo@…`.
    case gen3

    public var displayName: String {
        switch self {
        case .gen1: "gen1 (pwr/om)"
        case .gen2: "gen2 (D03-02)"
        case .gen3: "gen3 (D03102)"
        }
    }

    /// Detects the scheme from the keys of a `state.reported` object, or returns `nil`.
    ///
    /// Order matters only for pathological mixes; real devices use one scheme.
    /// - gen3: `D03102` present, or any key matching `^D0[0-9A-F]{4}$`
    /// - gen2: `D03-02` or `D01-05` present
    /// - gen1: `pwr` or `om` present
    public static func detect(in reported: [String: JSONValue]) -> KeyGeneration? {
        if reported["D03102"] != nil || reported.keys.contains(where: isGen3Key) {
            return .gen3
        }
        if reported["D03-02"] != nil || reported["D01-05"] != nil {
            return .gen2
        }
        if reported["pwr"] != nil || reported["om"] != nil {
            return .gen1
        }
        return nil
    }

    /// `^D0[0-9A-F]{4}$`
    static func isGen3Key(_ key: String) -> Bool {
        let ascii = Array(key.utf8)
        guard ascii.count == 6, ascii[0] == UInt8(ascii: "D"), ascii[1] == UInt8(ascii: "0") else { return false }
        return ascii[2...].allSatisfy { (0x30 ... 0x39).contains($0) || (0x41 ... 0x46).contains($0) }
    }
}
