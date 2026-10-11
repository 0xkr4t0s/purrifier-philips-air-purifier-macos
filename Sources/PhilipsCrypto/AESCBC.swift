import CommonCrypto

/// A minimal, type-safe wrapper around CommonCrypto's AES-128-CBC.
///
/// CryptoKit has no CBC mode, so this is the only place the package touches CommonCrypto.
/// Encryption uses CommonCrypto's PKCS#7 padding. Decryption runs without padding and strips
/// it here with strict checks (every pad byte equal, length 1–16), the same rules as
/// pycryptodome's `unpad`, so a bad-padding frame fails identically in Swift and Python.
enum AESCBC {
    static let blockSize = kCCBlockSizeAES128
    static let keySize = kCCKeySizeAES128

    static func encrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) throws(PhilipsCryptoError) -> [UInt8] {
        try crypt(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv, options: CCOptions(kCCOptionPKCS7Padding))
    }

    static func decrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) throws(PhilipsCryptoError) -> [UInt8] {
        let padded = try crypt(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv, options: 0)
        return try unpadPKCS7(padded)
    }

    static func unpadPKCS7(_ data: [UInt8]) throws(PhilipsCryptoError) -> [UInt8] {
        guard let last = data.last, !data.isEmpty, data.count.isMultiple(of: blockSize) else {
            throw .badPadding
        }
        let padLength = Int(last)
        guard (1 ... blockSize).contains(padLength),
              data.suffix(padLength).allSatisfy({ $0 == last })
        else {
            throw .badPadding
        }
        return Array(data.dropLast(padLength))
    }

    private static func crypt(
        _ operation: CCOperation,
        _ input: [UInt8],
        key: [UInt8],
        iv: [UInt8],
        options: CCOptions
    ) throws(PhilipsCryptoError) -> [UInt8] {
        precondition(key.count == keySize && iv.count == blockSize, "AES-128-CBC needs a 16-byte key and IV")
        var output = [UInt8](repeating: 0, count: input.count + blockSize)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            CCCrypt(
                operation,
                CCAlgorithm(kCCAlgorithmAES),
                options,
                key, key.count,
                iv,
                input, input.count,
                outputBuffer.baseAddress, outputCapacity,
                &moved
            )
        }
        guard status == kCCSuccess else { throw .cryptorFailure(status: status) }
        return Array(output.prefix(moved))
    }
}
