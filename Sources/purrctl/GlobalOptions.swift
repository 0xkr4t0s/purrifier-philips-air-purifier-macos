import AirLink
import ArgumentParser
import CoAPCore
import Foundation

/// Options shared by every subcommand. Each can go before or after the subcommand name.
struct GlobalOptions: ParsableArguments {
    @Option(name: [.customShort("H"), .long], help: "Purifier IP address or hostname. Default: $PURRIFIER_HOST.")
    var host: String?

    @Option(name: [.customShort("P"), .long], help: "CoAP port. Default: $PURRIFIER_PORT, else 5683.")
    var port: UInt16?

    @Flag(name: [.customShort("D"), .long], help: "Print every CoAP datagram (hex) and the decrypted JSON to stderr.")
    var debug = false

    @Flag(help: "Send requests as NON instead of CON, like aioairctrl does.")
    var non = false

    @Flag(help: "Allow writes whose values are not verified on hardware (gen1/gen2 devices).")
    var allowUnverified = false

    @Option(help: "Sync timeout in seconds.")
    var syncTimeout: Double = 4

    @Option(help: "Status timeout in seconds.")
    var statusTimeout: Double = 8

    @Option(help: "Control timeout in seconds.")
    var controlTimeout: Double = 6

    func validate() throws {
        for (name, value) in [("sync", syncTimeout), ("status", statusTimeout), ("control", controlTimeout)]
            where !(value > 0 && value <= 120) {
            throw ValidationError("--\(name)-timeout must be between 0 and 120 seconds.")
        }
    }

    func configuration(environment: [String: String] = ProcessInfo.processInfo
        .environment) throws -> SessionConfiguration {
        guard let host = host ?? environment["PURRIFIER_HOST"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw ValidationError("No device address. Pass --host <ip> or set PURRIFIER_HOST.")
        }
        let port: UInt16
        if let explicit = self.port {
            port = explicit
        } else if let text = environment["PURRIFIER_PORT"], !text.isEmpty {
            guard let parsed = UInt16(text), parsed > 0 else {
                throw ValidationError("PURRIFIER_PORT must be a port number (1–65535), got \"\(text)\".")
            }
            port = parsed
        } else {
            port = 5683
        }
        guard port > 0 else { throw ValidationError("--port must be 1–65535.") }

        var configuration = SessionConfiguration(host: host, port: port)
        configuration.syncTimeout = .milliseconds(Int(syncTimeout * 1000))
        configuration.statusTimeout = .milliseconds(Int(statusTimeout * 1000))
        configuration.controlTimeout = .milliseconds(Int(controlTimeout * 1000))
        configuration.messageType = non ? .nonConfirmable : .confirmable
        configuration.allowUnverifiedWrites = allowUnverified
        return configuration
    }

    /// Runs `body` with a session, prints failures for humans, and always closes the socket.
    func withSession(_ body: (PurifierSession) async throws -> Void) async throws {
        let configuration = try configuration()
        let session = PurifierSession(configuration: configuration, logger: debug ? DebugPrinter.log : nil)
        do {
            try await body(session)
            await session.close()
        } catch let error as PurifierError {
            await session.close()
            FileHandle.standardError.write(Data("purrctl: \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        } catch {
            await session.close()
            throw error
        }
    }
}

/// `--debug` output on stderr: each datagram as a one-line summary plus hex, and decrypted JSON.
enum DebugPrinter {
    static let log: WireLogger = { event in
        let line: String = switch event {
        case let .sent(bytes):
            format("→", bytes)
        case let .received(bytes):
            format("←", bytes)
        case let .decrypted(direction, json):
            "\(direction.rawValue) decrypted: \(json)"
        case let .note(text):
            "· \(text)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func format(_ arrow: String, _ bytes: [UInt8]) -> String {
        let summary = (try? CoAPMessage.decode(bytes)).map(\.description) ?? "<malformed>"
        return "\(arrow) \(summary)\n  \(Hex.encode(bytes, separator: " "))"
    }
}
