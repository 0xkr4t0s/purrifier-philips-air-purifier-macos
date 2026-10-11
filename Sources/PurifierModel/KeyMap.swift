/// Where each function lives in the status JSON for one key generation, and what values
/// to write. Every entry is a hypothesis until a dump from the owner's AC0850/70 confirms it
/// (see `Tests/Fixtures/ac0850-70/README.md`).
public struct KeyMap: Sendable, Hashable {
    public var power: String
    public var powerOn: JSONValue
    public var powerOff: JSONValue
    public var mode: String?
    public var modeValues: [PurifierMode: JSONValue]
    /// Read-only: the speed the fan is actually running at.
    public var fanSpeed: String?
    public var pm25: String?
    public var allergenIndex: String?
    public var preferredIndex: String?
    public var errorCode: String?
    public var filterRemainingHours: String?
    public var filterTotalHours: String?
    public var model: String?
    public var name: String?
    public var softwareVersion: String?
    public var childLock: String?
    /// Candidate keys for the display light; the first one present in status is used.
    public var displayLight: [String]
    /// `false` while the write literals for this generation are unverified on hardware.
    public var writesVerified: Bool

    public static func forGeneration(_ generation: KeyGeneration) -> KeyMap {
        switch generation {
        case .gen1: .gen1
        case .gen2: .gen2
        case .gen3: .gen3
        }
    }

    /// Gen3 (`AWS_Philips_AIR_Combo@…`), from an AC0850/11 `@1.2` dump in
    /// kongo09/philips-airpurifier-coap#139 and the integration's `PhilipsAC085011C` class.
    ///
    /// TODO(verify-ac0850-70): mode values 0/17/18 come from one community dump of an
    /// AC0850/11; confirm against the owner's AC0850/70 status dump before release.
    public static let gen3 = KeyMap(
        power: "D03102",
        powerOn: 1,
        powerOff: 0,
        mode: "D0310C",
        modeValues: [.auto: 0, .sleep: 17, .turbo: 18],
        fanSpeed: "D0310D",
        pm25: "D03221",
        allergenIndex: "D03120",
        preferredIndex: "D0312A",
        errorCode: "D03240",
        filterRemainingHours: "D0540E",
        filterTotalHours: "D05408",
        model: "D01S05",
        name: "D01S03",
        softwareVersion: "D01S12",
        // Absent from the AC0850/11 dump; exposed only if a device reports them.
        childLock: "D03103",
        displayLight: ["D0312D", "D03105"],
        // Written by the Home Assistant integration on real AC0850/11 units.
        writesVerified: true
    )

    /// Gen2 (`AWS_Philips_AIR@…`), keys from kongo09's `const.py` (`NEW_*`), value literals from
    /// its `PhilipsAC085011` class and the AC0850/20 status in issue #139 (`"D03-02": "ON"`).
    ///
    /// TODO(verify-gen2): we have not seen these literals accepted by a device ourselves, so
    /// writes require an explicit opt-in (`--allow-unverified`).
    public static let gen2 = KeyMap(
        power: "D03-02",
        powerOn: "ON",
        powerOff: "OFF",
        mode: "D03-12",
        modeValues: [.auto: "Auto General", .sleep: "Sleep", .turbo: "Turbo"],
        fanSpeed: nil,
        pm25: "D03-33",
        allergenIndex: "D03-32",
        preferredIndex: "D03-42",
        errorCode: nil,
        // TODO(verify-gen2): which D05-xx pair is the main filter is not established.
        filterRemainingHours: nil,
        filterTotalHours: nil,
        model: "D01-05",
        name: "D01-03",
        softwareVersion: "D01-21",
        childLock: nil,
        displayLight: ["D03-05"],
        writesVerified: false
    )

    /// Gen1 (py-air-control era). Read-only support: enough to identify the device.
    ///
    /// TODO(gen1): mode semantics (`mode` vs `om`) differ per model; writes are not mapped.
    public static let gen1 = KeyMap(
        power: "pwr",
        powerOn: "1",
        powerOff: "0",
        mode: nil,
        modeValues: [:],
        fanSpeed: nil,
        pm25: "pm25",
        allergenIndex: "iaql",
        preferredIndex: nil,
        errorCode: "err",
        filterRemainingHours: nil,
        filterTotalHours: nil,
        model: "modelid",
        name: "name",
        softwareVersion: "swversion",
        childLock: "cl",
        displayLight: ["uil"],
        writesVerified: false
    )
}
