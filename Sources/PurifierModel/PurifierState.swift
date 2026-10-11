/// User-facing fan modes. The AC0850 has exactly these three (plus off).
public enum PurifierMode: String, Sendable, Hashable, CaseIterable, Codable {
    case auto
    case sleep
    case turbo
}

/// Which air-quality number the device's display shows.
public enum PreferredIndex: Sendable, Hashable {
    /// Indoor allergen index (IAI).
    case allergenIndex
    case pm25
    case other(JSONValue)
}

/// Identity and diagnostics fields.
public struct DeviceInfo: Sendable, Hashable {
    public var model: String?
    public var name: String?
    public var softwareVersion: String?
    public var wifiVersion: String?
    public var deviceID: String?
    public var productID: String?
    public var rssi: Int?
}

/// What the device can do, inferred from which keys its status contains. Never hard-coded
/// per model: an AC0850/11 has no child-lock key, an AC0950 does.
public struct Capabilities: Sendable, Hashable {
    public var power = false
    public var modes: Set<PurifierMode> = []
    public var fanSpeedReadout = false
    public var pm25 = false
    public var allergenIndex = false
    public var preferredIndex = false
    public var filterLife = false
    public var childLock = false
    public var displayLight = false
    /// Whether writes for this generation have been seen to work on real hardware.
    public var verifiedWrites = false
}

/// A typed view of `state.reported`. Unknown keys stay available in `raw`.
public struct PurifierState: Sendable, Hashable {
    public let generation: KeyGeneration
    public let raw: [String: JSONValue]

    public var isOn: Bool?
    public var mode: PurifierMode?
    /// The mode value as reported, for modes this app doesn't name (or `nil` if absent).
    public var rawMode: JSONValue?
    public var fanSpeed: Int?
    public var pm25: Int?
    public var allergenIndex: Int?
    public var preferredIndex: PreferredIndex?
    /// Bitfield; 0 means no error.
    public var errorCode: Int?
    public var filterRemainingHours: Int?
    public var filterTotalHours: Int?
    /// Present only if the device reports a child-lock key.
    public var childLock: Bool?
    /// Present only if the device reports a display-light key. Raw value (0/1, or brightness).
    public var displayLight: Int?
    public var device: DeviceInfo
    public var capabilities: Capabilities

    /// Fraction of filter life left (0...1), when both hour counters are known.
    public var filterRemainingFraction: Double? {
        guard let remaining = filterRemainingHours, let total = filterTotalHours, total > 0 else { return nil }
        return min(1, max(0, Double(remaining) / Double(total)))
    }

    /// Parses a `state.reported` object. Throws if the key scheme can't be identified.
    public init(reported: [String: JSONValue]) throws(ModelError) {
        guard let generation = KeyGeneration.detect(in: reported) else {
            throw .unknownGeneration(sampleKeys: Array(reported.keys.sorted().prefix(8)))
        }
        self.init(reported: reported, generation: generation)
    }

    public init(reported: [String: JSONValue], generation: KeyGeneration) {
        let map = KeyMap.forGeneration(generation)
        func value(_ key: String?) -> JSONValue? { key.flatMap { reported[$0] } }

        self.generation = generation
        raw = reported

        let power = reported[map.power]
        isOn = power.map { reported in
            reported == map.powerOn || (reported.looseIntValue != nil && reported.looseIntValue == map.powerOn.looseIntValue)
        }
        rawMode = value(map.mode)
        mode = rawMode.flatMap { reportedMode in map.modeValues.first { $0.value == reportedMode }?.key }
        fanSpeed = value(map.fanSpeed)?.looseIntValue
        pm25 = value(map.pm25)?.looseIntValue
        allergenIndex = value(map.allergenIndex)?.looseIntValue
        preferredIndex = value(map.preferredIndex).map(Self.preferredIndex)
        errorCode = value(map.errorCode)?.looseIntValue
        filterRemainingHours = value(map.filterRemainingHours)?.looseIntValue
        filterTotalHours = value(map.filterTotalHours)?.looseIntValue
        childLock = value(map.childLock).map { $0.boolValue ?? ($0.looseIntValue == 1) }
        let lightKey = map.displayLight.first { reported[$0] != nil }
        displayLight = value(lightKey)?.looseIntValue

        device = DeviceInfo(
            model: value(map.model)?.stringValue,
            name: value(map.name)?.stringValue,
            softwareVersion: value(map.softwareVersion)?.stringValue,
            wifiVersion: reported["WifiVersion"]?.stringValue,
            deviceID: reported["DeviceId"]?.stringValue,
            productID: reported["ProductId"]?.stringValue,
            rssi: reported["rssi"]?.intValue
        )

        var capabilities = Capabilities()
        capabilities.power = power != nil
        capabilities.modes = rawMode == nil ? [] : Set(map.modeValues.keys)
        capabilities.fanSpeedReadout = fanSpeed != nil
        capabilities.pm25 = pm25 != nil
        capabilities.allergenIndex = allergenIndex != nil
        capabilities.preferredIndex = preferredIndex != nil
        capabilities.filterLife = filterRemainingHours != nil && filterTotalHours != nil
        capabilities.childLock = childLock != nil
        capabilities.displayLight = lightKey != nil
        capabilities.verifiedWrites = map.writesVerified
        self.capabilities = capabilities
    }

    private static func preferredIndex(_ value: JSONValue) -> PreferredIndex {
        switch value {
        case 0, "IAI": .allergenIndex
        case 1, "PM2.5": .pm25
        default: .other(value)
        }
    }
}

/// Unwraps `state.reported` from a decrypted status document.
public enum StatusDocument {
    public static func reported(from plaintext: some Collection<UInt8>) throws(ModelError) -> [String: JSONValue] {
        guard let reported = try JSONValue.parse(plaintext).objectValue?["state"]?.objectValue?["reported"]?.objectValue
        else {
            throw .missingReportedState
        }
        return reported
    }
}
