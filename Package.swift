// swift-tools-version: 6.0
//
// Purrifier — native macOS control for Philips Air+ purifiers over local encrypted CoAP.
// Not affiliated with or endorsed by Philips or Versuni.

import PackageDescription

let package = Package(
    name: "Purrifier",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CoAPCore", targets: ["CoAPCore"]),
        .library(name: "PhilipsCrypto", targets: ["PhilipsCrypto"]),
        .library(name: "PurifierModel", targets: ["PurifierModel"]),
        .library(name: "AirLink", targets: ["AirLink"]),
        .library(name: "FakePurifier", targets: ["FakePurifier"]),
        .executable(name: "purrctl", targets: ["purrctl"]),
        .executable(name: "fake-purifier", targets: ["fake-purifier"]),
    ],
    dependencies: [
        // The only third-party dependency, and only for the command-line tools.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // MARK: Libraries

        .target(name: "CoAPCore"),
        .target(name: "PhilipsCrypto"),
        .target(name: "PurifierModel"),
        .target(
            name: "AirLink",
            dependencies: ["CoAPCore", "PhilipsCrypto", "PurifierModel"]
        ),

        // MARK: Device simulator (used by tests and for manual runs)

        .target(
            name: "FakePurifier",
            dependencies: ["CoAPCore", "PhilipsCrypto", "PurifierModel"],
            path: "Tools/FakePurifier/FakePurifier"
        ),
        .executableTarget(
            name: "fake-purifier",
            dependencies: [
                "FakePurifier",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/FakePurifier/fake-purifier"
        ),

        // MARK: CLI

        .executableTarget(
            name: "purrctl",
            dependencies: [
                "AirLink",
                "PurifierModel",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: Tests

        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "CoAPCoreTests", dependencies: ["CoAPCore", "TestSupport"]),
        .testTarget(name: "PhilipsCryptoTests", dependencies: ["PhilipsCrypto", "TestSupport"]),
        .testTarget(name: "PurifierModelTests", dependencies: ["PurifierModel", "TestSupport"]),
        .testTarget(
            name: "AirLinkTests",
            dependencies: ["AirLink", "FakePurifier", "CoAPCore", "PhilipsCrypto", "PurifierModel", "TestSupport"]
        ),
        // Hardware-in-the-loop tests. They are skipped unless PURRIFIER_HIL_HOST is set,
        // so `swift test` in CI never touches a real device. See `make hil`.
        .testTarget(name: "HardwareTests", dependencies: ["AirLink", "PurifierModel"]),
    ],
    swiftLanguageModes: [.v6]
)
