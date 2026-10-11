import PurifierModel
import Testing
import TestSupport

private func reported(_ path: String) throws -> [String: JSONValue] {
    try #require(Fixtures.decode(JSONValue.self, from: path).objectValue)
}

/// AC0850/11 (`AWS_Philips_AIR_Combo@1.2`) dumps from kongo09/philips-airpurifier-coap#139.
struct AC085011FixtureTests {
    @Test(arguments: [
        ("ac0850-11/auto.json", true, PurifierMode.auto, 1, 3),
        ("ac0850-11/sleep.json", true, .sleep, 1, 1),
        ("ac0850-11/turbo.json", true, .turbo, 18, 2),
        ("ac0850-11/off.json", false, .auto, 0, 4),
    ])
    func parsesModeAndPower(path: String, isOn: Bool, mode: PurifierMode, fanSpeed: Int, pm25: Int) throws {
        let state = try PurifierState(reported: reported(path))
        #expect(state.generation == .gen3)
        #expect(state.isOn == isOn)
        #expect(state.mode == mode)
        #expect(state.fanSpeed == fanSpeed)
        #expect(state.pm25 == pm25)
    }

    @Test func parsesEverythingElse() throws {
        let state = try PurifierState(reported: reported("ac0850-11/sleep.json"))
        #expect(state.allergenIndex == 1)
        #expect(state.preferredIndex == .pm25)
        #expect(state.errorCode == 0)
        #expect(state.filterRemainingHours == 4788)
        #expect(state.filterTotalHours == 4800)
        #expect(state.filterRemainingFraction == 4788.0 / 4800.0)
        #expect(state.device.model == "AC0850/11")
        #expect(state.device.name == "Bedroom")
        #expect(state.device.softwareVersion == "0.1.3")
        #expect(state.device.wifiVersion == "AWS_Philips_AIR_Combo@1.2")
        #expect(state.device.deviceID == "b2af68eb397311ef80c263fa43fdd81f")
        #expect(state.device.rssi == -70)
    }

    @Test func capabilitiesComeFromKeyPresence() throws {
        let capabilities = try PurifierState(reported: reported("ac0850-11/auto.json")).capabilities
        #expect(capabilities.power)
        #expect(capabilities.modes == [.auto, .sleep, .turbo])
        #expect(capabilities.pm25 && capabilities.allergenIndex && capabilities.filterLife)
        #expect(capabilities.fanSpeedReadout && capabilities.preferredIndex)
        // Absent on the AC0850/11: no child lock, no display light.
        #expect(!capabilities.childLock)
        #expect(!capabilities.displayLight)
        #expect(capabilities.verifiedWrites)
    }

    @Test func childLockAndLightAppearOnlyWhenReported() throws {
        var raw = try reported("ac0850-11/auto.json")
        raw["D03103"] = 1
        raw["D03105"] = 115
        let state = try PurifierState(reported: raw)
        #expect(state.childLock == true)
        #expect(state.displayLight == 115)
        #expect(state.capabilities.childLock && state.capabilities.displayLight)
    }

    @Test func unknownModeIsKeptRaw() throws {
        var raw = try reported("ac0850-11/auto.json")
        raw["D0310C"] = 3
        let state = try PurifierState(reported: raw)
        #expect(state.mode == nil)
        #expect(state.rawMode == 3)
    }
}

/// The owner's own dumps. Empty until captured (see `Tests/Fixtures/ac0850-70/README.md`).
struct AC085070FixtureTests {
    static let files = (try? Fixtures.jsonFiles(in: "ac0850-70")) ?? []

    @Test(.enabled(if: !files.isEmpty, "no AC0850/70 dumps captured yet"), arguments: files)
    func parses(path: String) throws {
        let state = try PurifierState(reported: reported(path))
        #expect(state.device.model?.hasPrefix("AC0850") == true)
        #expect(state.isOn != nil)
    }
}

struct GenerationDetectionTests {
    @Test(arguments: [
        ("ac0850-11/auto.json", KeyGeneration.gen3),
        ("generations/gen2-ac0850-20.json", .gen2),
        ("generations/gen1-ac3033-14.json", .gen1),
    ])
    func detectsFixtures(path: String, generation: KeyGeneration) throws {
        #expect(try KeyGeneration.detect(in: reported(path)) == generation)
    }

    @Test(arguments: [
        (["D03102": 1] as [String: JSONValue], KeyGeneration?.some(.gen3)),
        (["D0310C": 17], .gen3),
        (["D05408": 4800], .gen3),
        (["D03-02": "ON"], .gen2),
        (["D01-05": "AC0850/20"], .gen2),
        (["pwr": "1"], .gen1),
        (["om": "s"], .gen1),
        (["D01S05": "AC0850/11"], nil), // 'S' isn't hex, so alone it isn't enough
        (["d03102": 1], nil),
        (["D031020": 1], nil),
        (["rssi": -70, "WifiVersion": "x"], nil),
        ([:], nil),
    ])
    func detectsByKeys(keys: [String: JSONValue], generation: KeyGeneration?) {
        #expect(KeyGeneration.detect(in: keys) == generation)
    }

    @Test func unknownGenerationThrows() {
        #expect(throws: ModelError.self) { try PurifierState(reported: ["foo": 1]) }
    }

    @Test func gen2FixtureParses() throws {
        let state = try PurifierState(reported: reported("generations/gen2-ac0850-20.json"))
        #expect(state.isOn == true)
        #expect(state.mode == .auto)
        #expect(state.pm25 == 2)
        #expect(state.allergenIndex == 1)
        #expect(state.preferredIndex == .pm25)
        #expect(state.device.model == "AC0850/20")
        #expect(state.displayLight == 100)
        #expect(!state.capabilities.verifiedWrites)
    }

    @Test func gen1FixtureParses() throws {
        let state = try PurifierState(reported: reported("generations/gen1-ac3033-14.json"))
        #expect(state.isOn == true)
        #expect(state.mode == nil)
        #expect(state.pm25 == 3)
        #expect(state.childLock == false)
        #expect(state.device.model == "AC3033/14")
    }
}
