import CryptoKit
import Foundation

/// The payload "encryption" used by Philips Air+ purifiers on local CoAP.
///
/// The name is deliberate. **This is obfuscation, not security**:
///
/// - The secret (`"JiangPan"`) is a constant shared by every device and published in
///   several open-source projects.
/// - The AES key and IV are the ASCII *characters* of an uppercase MD5 hex digest, so each
///   16-byte key holds only 16 hex digits: 64 bits of effective entropy, and in any case it
///   is derived from the counter, which travels in cleartext at the start of every frame.
///   Anyone who can see a frame can decrypt it.
/// - The trailing SHA-256 is **unkeyed**. It detects corruption but gives no authenticity:
///   anyone can compute it, so anyone on the LAN can forge a valid frame.
/// - CBC with a counter-derived IV is deterministic: the same counter and plaintext always
///   give the same ciphertext.
///
/// Frame layout (all ASCII):
///
/// ```
/// counter (8 hex) ‖ AES-128-CBC-PKCS7(plaintext) as uppercase hex ‖ SHA-256(counter ‖ cipherhex) as 64 uppercase hex
/// ```
///
/// Implemented from py-air-control's `coap_client.py` and aioairctrl's `encryption.py`, and
/// checked against aioairctrl with `Tools/gen_vectors.py`.
public enum LegacyPhilipsCipher {
    /// The protocol's hard-coded "secret".
    public static let secret = "JiangPan"

    /// Width of the counter at the start of a frame. The decrypt side always assumes 8.
    public static let counterLength = 8
    /// Width of the trailing digest (SHA-256 as hex).
    public static let digestLength = 64
    /// Smallest possible frame: counter, one AES block (32 hex digits) and the digest.
    public static let minimumFrameLength = counterLength + 32 + digestLength

    /// Key and IV for one counter value.
    public struct KeyMaterial: Sendable, Hashable {
        /// The uppercase MD5 hex digest of `secret + counter` (32 ASCII characters).
        public let digestHex: String
        /// The ASCII bytes of `digestHex[0..<16]`.
        public let key: [UInt8]
        /// The ASCII bytes of `digestHex[16..<32]`.
        public let iv: [UInt8]

        public var keyASCII: String {
            String(decoding: key, as: UTF8.self)
        }

        public var ivASCII: String {
            String(decoding: iv, as: UTF8.self)
        }
    }

    /// `h = uppercase hex(MD5(ASCII(secret + counter)))`; key = ASCII(h[0..<16]), iv = ASCII(h[16..<32]).
    public static func deriveKeyIV(counterHex: String) -> KeyMaterial {
        let md5 = Insecure.MD5.hash(data: Data((secret + counterHex).utf8))
        let digestHex = HexText.encode(md5)
        let ascii = Array(digestHex.utf8)
        return KeyMaterial(digestHex: digestHex, key: Array(ascii[0 ..< 16]), iv: Array(ascii[16 ..< 32]))
    }

    /// `uppercase hex(SHA-256(ASCII(counter + ciphertextHex)))`.
    public static func digest(counterHex: String, ciphertextHex: String) -> String {
        HexText.encode(SHA256.hash(data: Data((counterHex + ciphertextHex).utf8)))
    }

    /// Builds a frame for an **already incremented** counter. The caller (the session actor)
    /// owns the counter and must call `PhilipsCounter.advance(policy:)` first; this function
    /// never changes it, which keeps it pure and testable against fixed vectors.
    public static func seal(
        _ plaintext: some DataProtocol,
        counter: PhilipsCounter
    ) throws(PhilipsCryptoError) -> String {
        let material = deriveKeyIV(counterHex: counter.hex)
        let ciphertext = try AESCBC.encrypt(Array(plaintext), key: material.key, iv: material.iv)
        let ciphertextHex = HexText.encode(ciphertext)
        return counter.hex + ciphertextHex + digest(counterHex: counter.hex, ciphertextHex: ciphertextHex)
    }

    public static func seal(_ plaintext: String, counter: PhilipsCounter) throws(PhilipsCryptoError) -> String {
        try seal(Data(plaintext.utf8), counter: counter)
    }

    /// A decrypted frame.
    public struct Opened: Sendable, Hashable {
        /// The sender's counter, taken from the first 8 characters of the frame.
        public let counter: String
        public let plaintext: [UInt8]

        public var text: String? {
            String(data: Data(plaintext), encoding: .utf8)
        }
    }

    /// Verifies and decrypts a frame.
    ///
    /// Steps, in this order, matching py-air-control: split into counter (first 8 characters),
    /// digest (last 64) and ciphertext (the middle, uppercased); recompute and compare the
    /// digest; hex-decode; AES-CBC-decrypt with the counter's key and IV; strip PKCS#7 padding.
    ///
    /// Note: aioairctrl 0.3.1 does *not* uppercase the middle before hashing. The two only
    /// differ for frames with lowercase ciphertext, which no device is known to send.
    public static func open(_ frame: String) throws(PhilipsCryptoError) -> Opened {
        let ascii = Array(frame.utf8)
        guard ascii.allSatisfy({ $0 < 0x80 }) else { throw .malformedFrame("frame is not ASCII") }
        guard ascii.count >= minimumFrameLength else { throw .frameTooShort(length: ascii.count) }

        let counter = String(decoding: ascii[0 ..< counterLength], as: UTF8.self)
        let ciphertextHex = String(decoding: ascii[counterLength ..< ascii.count - digestLength], as: UTF8.self)
            .uppercased()
        let receivedDigest = String(decoding: ascii[(ascii.count - digestLength)...], as: UTF8.self)

        // Case-sensitive, as in both references. Constant-time comparison would buy nothing:
        // the digest is unkeyed, so there is no secret to leak through timing.
        guard receivedDigest == digest(counterHex: counter, ciphertextHex: ciphertextHex) else {
            throw .digestMismatch
        }
        // A digest can match and the ciphertext still be unusable: for example a sender using
        // an unpadded 9-digit counter shifts one digit into the "ciphertext", which is then odd-length.
        guard let ciphertext = HexText.decode(ciphertextHex) else {
            throw .malformedFrame("ciphertext is not valid hex (\(ciphertextHex.utf8.count) characters)")
        }
        guard ciphertext.count.isMultiple(of: AESCBC.blockSize) else {
            throw .malformedFrame("ciphertext is \(ciphertext.count) bytes, not a multiple of 16")
        }
        let material = deriveKeyIV(counterHex: counter)
        let plaintext = try AESCBC.decrypt(ciphertext, key: material.key, iv: material.iv)
        return Opened(counter: counter, plaintext: plaintext)
    }
}

public enum PhilipsCryptoError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A counter that isn't 1–16 hex digits.
    case invalidCounter(String)
    /// A fixed-width policy was asked to increment a counter that isn't 8 digits wide.
    case unexpectedCounterWidth(String)
    /// `fixedWidthStrict` reached `FFFFFFFF`. Resync to get a fresh counter.
    case counterExhausted
    case frameTooShort(length: Int)
    case malformedFrame(String)
    /// The trailing SHA-256 doesn't match. Corruption, a stale counter, or not a Philips frame.
    case digestMismatch
    /// The decrypted plaintext doesn't end in valid PKCS#7 padding (usually the wrong key).
    case badPadding
    /// CommonCrypto returned an unexpected status.
    case cryptorFailure(status: Int32)

    public var description: String {
        switch self {
        case let .invalidCounter(value): "invalid counter \"\(value)\" (expected hex digits)"
        case let .unexpectedCounterWidth(value): "counter \"\(value)\" is not 8 hex digits wide"
        case .counterExhausted: "counter reached FFFFFFFF; a resync is required"
        case let .frameTooShort(length): "encrypted frame too short (\(length) characters)"
        case let .malformedFrame(reason): "malformed encrypted frame: \(reason)"
        case .digestMismatch: "frame digest mismatch (corrupted frame or stale counter)"
        case .badPadding: "invalid PKCS#7 padding after decryption"
        case let .cryptorFailure(status): "CommonCrypto error \(status)"
        }
    }
}
