@testable import PhilipsCrypto
import Testing
import TestSupport

/// Checks the Swift cipher against vectors produced by aioairctrl (`Tools/gen_vectors.py`).
struct CryptoVectorTests {
    struct File: Decodable {
        struct KeyDerivation: Decodable, Sendable {
            let counter, md5Hex, keyAscii, ivAscii: String
        }

        struct Frame: Decodable, Sendable, CustomTestStringConvertible {
            let counter, plaintext, ciphertextHex, digest, frame: String
            var testDescription: String { "\(counter) / \(plaintext.prefix(24))…" }
        }

        struct Encrypt: Decodable, Sendable {
            let counterBefore, counterUsed, plaintext, frame: String
        }

        struct Increment: Decodable, Sendable {
            let before, fixedWidthWrapping, unpadded: String
        }

        struct Negative: Decodable, Sendable, CustomTestStringConvertible {
            let name, frame, error: String
            let referenceError: String?
            var testDescription: String { name }
        }

        let secret: String
        let keyDerivation: [KeyDerivation]
        let frames: [Frame]
        let encrypt: [Encrypt]
        let increments: [Increment]
        let negative: [Negative]
    }

    static let file: File? = try? Fixtures.decode(File.self, from: "crypto_vectors.json")
    static var frames: [File.Frame] { file?.frames ?? [] }
    static var negatives: [File.Negative] { file?.negative ?? [] }

    @Test func vectorsLoaded() throws {
        let file = try #require(Self.file)
        #expect(file.secret == LegacyPhilipsCipher.secret)
        #expect(Set(file.frames.map(\.counter)) == ["0000000A", "08ABBEC7", "7FFFFFFF", "FFFFFFFF"])
        #expect(file.frames.count == 12)
        #expect(file.negative.count >= 3)
    }

    @Test func keyDerivationMatchesReference() throws {
        for vector in try #require(Self.file).keyDerivation {
            let material = LegacyPhilipsCipher.deriveKeyIV(counterHex: vector.counter)
            #expect(material.digestHex == vector.md5Hex)
            #expect(material.keyASCII == vector.keyAscii)
            #expect(material.ivASCII == vector.ivAscii)
            #expect(material.key.count == 16 && material.iv.count == 16)
        }
    }

    @Test("seal produces byte-identical frames", arguments: frames)
    func sealMatchesReference(vector: File.Frame) throws {
        let frame = try LegacyPhilipsCipher.seal(vector.plaintext, counter: PhilipsCounter(hex: vector.counter))
        #expect(frame == vector.frame)
        #expect(LegacyPhilipsCipher.digest(counterHex: vector.counter, ciphertextHex: vector.ciphertextHex) == vector.digest)
    }

    @Test("open recovers the plaintext", arguments: frames)
    func openMatchesReference(vector: File.Frame) throws {
        let opened = try LegacyPhilipsCipher.open(vector.frame)
        #expect(opened.counter == vector.counter)
        #expect(opened.text == vector.plaintext)
    }

    /// The full sender path: increment (aioairctrl policy), then seal. Includes the
    /// `FFFFFFFF` → `00000000` wrap.
    @Test func encryptWithIncrementMatchesReference() throws {
        for vector in try #require(Self.file).encrypt {
            var counter = try PhilipsCounter(hex: vector.counterBefore)
            let used = try counter.advance(policy: .fixedWidthWrapping)
            #expect(used.hex == vector.counterUsed)
            #expect(try LegacyPhilipsCipher.seal(vector.plaintext, counter: used) == vector.frame)
        }
    }

    @Test func incrementPoliciesMatchReferences() throws {
        for vector in try #require(Self.file).increments {
            let counter = try PhilipsCounter(hex: vector.before)
            #expect(try counter.incremented(policy: .fixedWidthWrapping).hex == vector.fixedWidthWrapping)
            #expect(try counter.incremented(policy: .unpadded).hex == vector.unpadded)
        }
    }

    @Test("open rejects malformed frames", arguments: negatives)
    func negativeCases(vector: File.Negative) {
        #expect(vector.referenceError != nil, "the Python reference must also reject \(vector.name)")
        do {
            let opened = try LegacyPhilipsCipher.open(vector.frame)
            Issue.record("expected \(vector.error), decrypted \(opened.plaintext.count) bytes")
        } catch {
            #expect(Self.name(of: error) == vector.error)
        }
    }

    private static func name(of error: PhilipsCryptoError) -> String {
        switch error {
        case .digestMismatch: "digestMismatch"
        case .badPadding: "badPadding"
        case .frameTooShort: "frameTooShort"
        case .malformedFrame: "malformedFrame"
        default: "\(error)"
        }
    }
}
