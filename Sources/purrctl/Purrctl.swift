import AirLink
import ArgumentParser
import Foundation
import PurifierModel

@main
struct Purrctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purrctl",
        abstract: "Local control for Philips Air+ purifiers over encrypted CoAP. No cloud.",
        discussion: """
        The device address comes from --host/--port or PURRIFIER_HOST/PURRIFIER_PORT.
        Examples:
          purrctl --host 192.168.1.50 status
          purrctl --host 192.168.1.50 status --json
          purrctl --host 192.168.1.50 set-mode sleep
          purrctl --host 192.168.1.50 set -I D0310C=18
          purrctl --host 192.168.1.50 --debug status

        Part of Purrifier. Not affiliated with or endorsed by Philips or Versuni.
        """,
        version: "0.1.0-dev",
        subcommands: [Sync.self, Status.self, Observe.self, Set.self, SetMode.self, Power.self]
    )

    // Declared here too so that `purrctl --host X status` parses (options before the subcommand).
    @OptionGroup var options: GlobalOptions
}

// MARK: - Subcommands

extension Purrctl {
    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Perform the sync handshake and print the counter.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await options.withSession { session in
                let counter = try await session.sync()
                print(counter.hex)
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read the current status once.")
        @OptionGroup var options: GlobalOptions

        @Flag(help: "Print state.reported as JSON (compare with `aioairctrl status -J`).")
        var json = false

        @Flag(help: "Print the decrypted status document exactly as the device sent it.")
        var raw = false

        func validate() throws {
            if json, raw { throw ValidationError("--json and --raw are mutually exclusive.") }
        }

        func run() async throws {
            try await options.withSession { session in
                let snapshot = try await session.statusSnapshot()
                if raw {
                    print(snapshot.document)
                } else if json {
                    print(JSONValue.object(snapshot.reported).pythonJSON)
                } else {
                    print(try StatusFormatter.summary(PurifierState(reported: snapshot.reported)))
                }
            }
        }
    }

    struct Observe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stream status updates until interrupted (Ctrl-C).",
            discussion: "Milestone 1: a single observation; it ends if the device stops pushing."
        )
        @OptionGroup var options: GlobalOptions

        @Flag(help: "One JSON object per line.")
        var json = false

        func run() async throws {
            try await options.withSession { session in
                for try await reported in await session.observe() {
                    if json {
                        print(JSONValue.object(reported).pythonJSON)
                    } else if let state = try? PurifierState(reported: reported) {
                        print(StatusFormatter.line(state))
                    } else {
                        print(JSONValue.object(reported).pythonJSON)
                    }
                    fflush(stdout)
                }
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send raw KEY=VALUE pairs (aioairctrl `set` semantics).",
            discussion: """
            Values are strings unless -I is given; `true`/`false` are always booleans.
            The key generation is read from the device before anything is written.
            """
        )
        @OptionGroup var options: GlobalOptions

        @Flag(name: [.customShort("I"), .customLong("int")], help: "Encode values as integers.")
        var asInteger = false

        @Argument(help: "KEY=VALUE pairs, e.g. D0310C=18.")
        var assignments: [String]

        func run() async throws {
            let values: [DesiredValue]
            do {
                values = try assignments.map { try DesiredValue.parse(assignment: $0, asInteger: asInteger) }
            } catch {
                throw ValidationError("\(error)")
            }
            try await options.withSession { session in
                try await session.send(.raw(values))
                print("OK: set \(values.map(\.description).joined(separator: " "))")
            }
        }
    }

    struct SetMode: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-mode",
            abstract: "Switch the purifier on in auto, sleep or turbo mode."
        )
        @OptionGroup var options: GlobalOptions

        @Argument(help: "auto, sleep or turbo.")
        var mode: PurifierMode

        func run() async throws {
            try await options.withSession { session in
                try await session.send(.mode(mode))
                print("OK: mode \(mode.rawValue)")
            }
        }
    }

    struct Power: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch the purifier on or off.")
        @OptionGroup var options: GlobalOptions

        @Argument(help: "on or off.")
        var state: PowerState

        enum PowerState: String, ExpressibleByArgument, CaseIterable {
            case on, off
        }

        func run() async throws {
            try await options.withSession { session in
                try await session.send(.power(state == .on))
                print("OK: power \(state.rawValue)")
            }
        }
    }
}

extension PurifierMode: ExpressibleByArgument {}
