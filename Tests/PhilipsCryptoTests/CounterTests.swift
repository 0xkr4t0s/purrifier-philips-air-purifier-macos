import Testing
@testable import PhilipsCrypto

struct CounterTests {
    @Test(arguments: ["", "G0000000", "0x000001", " 0000001", "11112222333344445"])
    func rejectsInvalidCounters(text: String) {
        #expect(throws: PhilipsCryptoError.invalidCounter(text)) { try PhilipsCounter(hex: text) }
    }

    @Test func keepsTextExactlyAsReceived() throws {
        // The key derivation hashes the ASCII text, so case must be preserved.
        let lower = try PhilipsCounter(hex: "08abbec7")
        #expect(lower.hex == "08abbec7")
        #expect(LegacyPhilipsCipher.deriveKeyIV(counterHex: lower.hex)
            != LegacyPhilipsCipher.deriveKeyIV(counterHex: "08ABBEC7"))
        // ...but an increment always produces uppercase.
        #expect(try lower.incremented().hex == "08ABBEC8")
    }

    @Test func fixedWidthWrappingWraps() throws {
        #expect(try PhilipsCounter(hex: "FFFFFFFF").incremented(policy: .fixedWidthWrapping).hex == "00000000")
    }

    @Test func fixedWidthStrictRefusesToWrap() throws {
        let counter = try PhilipsCounter(hex: "FFFFFFFF")
        #expect(throws: PhilipsCryptoError.counterExhausted) { try counter.incremented(policy: .fixedWidthStrict) }
        #expect(try PhilipsCounter(hex: "FFFFFFFE").incremented(policy: .fixedWidthStrict).hex == "FFFFFFFF")
    }

    @Test(arguments: [CounterWidthPolicy.fixedWidthWrapping, .fixedWidthStrict])
    func fixedWidthPoliciesRequireEightDigits(policy: CounterWidthPolicy) throws {
        for text in ["B", "8ABBEC8", "100000000"] {
            let counter = try PhilipsCounter(hex: text)
            #expect(throws: PhilipsCryptoError.unexpectedCounterWidth(text)) { try counter.incremented(policy: policy) }
        }
    }

    @Test func unpaddedGrowsAndShrinks() throws {
        #expect(try PhilipsCounter(hex: "0000000A").incremented(policy: .unpadded).hex == "B")
        #expect(try PhilipsCounter(hex: "FFFFFFFF").incremented(policy: .unpadded).hex == "100000000")
    }

    @Test func advanceMutatesAndReturnsNewValue() throws {
        var counter = try PhilipsCounter(hex: "0000000A")
        let first = try counter.advance()
        let second = try counter.advance()
        #expect(first.hex == "0000000B")
        #expect(second.hex == "0000000C")
        #expect(counter == second)
    }

    @Test func defaultPolicyMatchesAioairctrl() {
        #expect(CounterWidthPolicy.default == .fixedWidthWrapping)
    }
}

struct CipherTests {
    @Test func roundTripsArbitraryPlaintexts() throws {
        let counter = try PhilipsCounter(hex: "12345678")
        for length in [0, 1, 15, 16, 17, 31, 32, 33, 1000] {
            let plaintext = String(repeating: "é", count: length)
            let frame = try LegacyPhilipsCipher.seal(plaintext, counter: counter)
            #expect(try LegacyPhilipsCipher.open(frame).text == plaintext)
        }
    }

    @Test func frameStructure() throws {
        let frame = try LegacyPhilipsCipher.seal("{}", counter: PhilipsCounter(hex: "0000000A"))
        #expect(frame.hasPrefix("0000000A"))
        #expect(frame.utf8.count == 8 + 32 + 64) // "{}" pads to one block
        #expect(frame == frame.uppercased())
    }

    @Test func acceptsLowercaseCiphertextLikePyAirControl() throws {
        // py-air-control uppercases the middle before hashing; aioairctrl doesn't.
        let frame = try LegacyPhilipsCipher.seal("hello", counter: PhilipsCounter(hex: "0000000A"))
        let ascii = Array(frame.utf8)
        let middle = String(decoding: ascii[8 ..< ascii.count - 64], as: UTF8.self).lowercased()
        let lowered = String(decoding: ascii[..<8], as: UTF8.self) + middle + String(
            decoding: ascii.suffix(64),
            as: UTF8.self
        )
        #expect(try LegacyPhilipsCipher.open(lowered).text == "hello")
    }

    @Test func nonASCIIFrameIsMalformed() {
        let frame = "0000000A" + String(repeating: "é", count: 100)
        #expect(throws: PhilipsCryptoError.malformedFrame("frame is not ASCII")) { try LegacyPhilipsCipher.open(frame) }
    }

    @Test(arguments: [
        ([UInt8](repeating: 0x10, count: 16), [UInt8]()),
        (Array("abc".utf8) + [UInt8](repeating: 13, count: 13), Array("abc".utf8)),
    ])
    func unpadAcceptsValidPadding(padded: [UInt8], expected: [UInt8]) throws {
        #expect(try AESCBC.unpadPKCS7(padded) == expected)
    }

    @Test(arguments: [
        [UInt8](),
        [UInt8](repeating: 0, count: 16),
        [UInt8](repeating: 0x11, count: 16),
        Array("abcdefghijklm".utf8) + [3, 2, 3],
        [UInt8](repeating: 1, count: 15),
    ])
    func unpadRejectsInvalidPadding(padded: [UInt8]) {
        #expect(throws: PhilipsCryptoError.badPadding) { try AESCBC.unpadPKCS7(padded) }
    }
}
