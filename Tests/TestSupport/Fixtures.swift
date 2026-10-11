import Foundation

/// Locates files under `Tests/Fixtures`. Fixtures are read from the source tree (via
/// `#filePath`) rather than bundled as resources, so the Python generator and the Swift
/// tests share one copy.
public enum Fixtures {
    public static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TestSupport
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)

    public static func url(_ relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    public static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from relativePath: String) throws -> T {
        try JSONDecoder().decode(type, from: data(relativePath))
    }

    /// Relative paths of all `.json` files in a fixture subdirectory, sorted.
    public static func jsonFiles(in subdirectory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(subdirectory).path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { "\(subdirectory)/\($0)" }
    }
}

extension Array where Element == UInt8 {
    /// Test helper: bytes from uppercase or lowercase hex. Traps on invalid input.
    public init(hex: String) {
        let ascii = Array(hex.utf8)
        precondition(ascii.count.isMultiple(of: 2), "odd-length hex")
        self = stride(from: 0, to: ascii.count, by: 2).map { index in
            UInt8(String(decoding: ascii[index ..< index + 2], as: UTF8.self), radix: 16)!
        }
    }
}
