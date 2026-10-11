import Testing
import TestSupport
@testable import CoAPCore

/// Golden-byte tests against datagrams encoded by aiocoap (see `Tools/gen_vectors.py`).
struct CoAPVectorTests {
    struct Vector: Decodable, CustomTestStringConvertible, Sendable {
        struct Option: Decodable, Sendable {
            let number: UInt16
            let valueHex: String
        }

        let name: String
        let type: String
        let code: UInt8
        let messageID: UInt16
        let tokenHex: String
        let options: [Option]
        let payloadHex: String
        let bytesHex: String

        var testDescription: String {
            name
        }

        var message: CoAPMessage {
            let types: [String: CoAPMessage.MessageType] = [
                "CON": .confirmable, "NON": .nonConfirmable, "ACK": .acknowledgement, "RST": .reset,
            ]
            return CoAPMessage(
                type: types[type] ?? .reset,
                code: .init(rawValue: code),
                messageID: messageID,
                token: [UInt8](hex: tokenHex),
                options: options.map { CoAPOption(.init(rawValue: $0.number), value: [UInt8](hex: $0.valueHex)) },
                payload: [UInt8](hex: payloadHex)
            )
        }
    }

    struct File: Decodable {
        let messages: [Vector]
    }

    static let vectors: [Vector] = (try? Fixtures.decode(File.self, from: "coap_vectors.json").messages) ?? []

    @Test func vectorsLoaded() {
        #expect(Self.vectors.count >= 20)
    }

    @Test("encode matches aiocoap", arguments: vectors)
    func encodeMatchesReference(vector: Vector) throws {
        let bytes = try vector.message.encode()
        #expect(Hex.encode(bytes) == vector.bytesHex)
    }

    @Test("decode recovers every field", arguments: vectors)
    func decodeMatchesReference(vector: Vector) throws {
        let decoded = try CoAPMessage.decode([UInt8](hex: vector.bytesHex))
        #expect(decoded == vector.message)
    }

    @Test func syncRequestShape() throws {
        let vector = try #require(Self.vectors.first { $0.name == "syncRequestNON" })
        let message = try CoAPMessage.decode([UInt8](hex: vector.bytesHex))
        #expect(message.type == .nonConfirmable)
        #expect(message.code == .post)
        #expect(message.uriPath == "/sys/dev/sync")
        #expect(String(decoding: message.payload, as: UTF8.self) == "0A1B2C3D")
    }

    @Test func notificationAccessors() throws {
        let vector = try #require(Self.vectors.first { $0.name == "notificationCON" })
        let message = try CoAPMessage.decode([UInt8](hex: vector.bytesHex))
        #expect(message.observe == 0xABCD)
        #expect(message.maxAge == 60)
        #expect(message.contentFormat == 50)
    }
}
