import Testing
@testable import CoAPCore

struct CoAPCodecTests {
    // MARK: Hand-computed golden bytes

    @Test func observeRegistrationGoldenBytes() throws {
        var message = CoAPMessage(type: .confirmable, code: .get, messageID: 0x0102, token: [0xCA, 0xFE, 0xBA, 0xBE])
        message.setURIPath("/sys/dev/status")
        message.observe = 0
        let expected: [UInt8] = [
            0x44, 0x01, 0x01, 0x02, // ver 1, CON, TKL 4 | GET | mid
            0xCA, 0xFE, 0xBA, 0xBE, // token
            0x60, // Observe (delta 6), length 0: the value 0 is encoded as zero bytes
            0x53, 0x73, 0x79, 0x73, // Uri-Path (delta 5) "sys"
            0x03, 0x64, 0x65, 0x76, // Uri-Path (delta 0) "dev"
            0x06, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, // Uri-Path "status"
        ]
        #expect(try message.encode() == expected)
    }

    @Test func emptyAckIsFourBytes() throws {
        #expect(try CoAPMessage.empty(type: .acknowledgement, messageID: 0xABCD).encode() == [0x60, 0x00, 0xAB, 0xCD])
    }

    @Test func payloadMarkerOnlyWithPayload() throws {
        let without = try CoAPMessage(type: .nonConfirmable, code: .post, messageID: 1).encode()
        #expect(!without.contains(0xFF))
        let with = try CoAPMessage(type: .nonConfirmable, code: .post, messageID: 1, payload: [0x41]).encode()
        #expect(with.suffix(2) == [0xFF, 0x41])
    }

    // MARK: Option delta / length extension boundaries

    @Test(arguments: [
        (0, 0, []), (12, 12, []), (13, 13, [0]), (14, 13, [1]),
        (268, 13, [255]), (269, 14, [0, 0]), (270, 14, [0, 1]),
        (65804, 14, [0xFF, 0xFF]),
    ] as [(Int, UInt8, [UInt8])])
    func extendedField(value: Int, nibble: UInt8, extended: [UInt8]) {
        let result = CoAPMessage.extendedField(value)
        #expect(result.nibble == nibble)
        #expect(result.extended == extended)
    }

    @Test(arguments: [0, 1, 12, 13, 14, 268, 269, 270, 1000, 65535])
    func optionNumberRoundTrip(number: Int) throws {
        let option = CoAPOption(.init(rawValue: UInt16(number)), value: [0x01])
        let message = CoAPMessage(type: .confirmable, code: .get, messageID: 7, options: [option])
        let decoded = try CoAPMessage.decode(message.encode())
        #expect(decoded.options == [option])
    }

    @Test(arguments: [0, 1, 12, 13, 14, 268, 269, 270, 1024, 65804])
    func optionLengthRoundTrip(length: Int) throws {
        let option = CoAPOption(.init(rawValue: 2048), value: [UInt8](repeating: 0x5A, count: length))
        let message = CoAPMessage(type: .nonConfirmable, code: .post, messageID: 7, options: [option], payload: [1])
        let decoded = try CoAPMessage.decode(message.encode())
        #expect(decoded == message)
    }

    @Test func optionsAreSortedStably() throws {
        let message = CoAPMessage(
            type: .confirmable, code: .get, messageID: 1,
            options: [
                CoAPOption(.uriPath, string: "a"),
                CoAPOption(.observe, uint: 0),
                CoAPOption(.uriPath, string: "b"),
                CoAPOption(.contentFormat, uint: 0),
            ]
        )
        let decoded = try CoAPMessage.decode(message.encode())
        #expect(decoded.options.map(\.number) == [.observe, .uriPath, .uriPath, .contentFormat])
        #expect(decoded.uriPath == "/a/b")
    }

    // MARK: uint options

    @Test(arguments: [
        (0, []), (1, [1]), (255, [255]), (256, [1, 0]), (0xFFFFFF, [0xFF, 0xFF, 0xFF]),
        (0xFFFF_FFFF, [0xFF, 0xFF, 0xFF, 0xFF]),
    ] as [(UInt32, [UInt8])])
    func uintOptionEncoding(value: UInt32, bytes: [UInt8]) {
        let option = CoAPOption(.observe, uint: value)
        #expect(option.value == bytes)
        #expect(option.uintValue == value)
    }

    @Test func oversizedUIntIsNil() {
        #expect(CoAPOption(.maxAge, value: [1, 2, 3, 4, 5]).uintValue == nil)
    }

    // MARK: Round trips

    @Test func randomizedRoundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 500 {
            let type = try #require(CoAPMessage.MessageType.allCases.randomElement(using: &generator))
            let code = CoAPMessage.Code(rawValue: .random(in: 1 ... 255, using: &generator))
            let token = (0 ..< Int.random(in: 0 ... 8, using: &generator)).map { _ in UInt8.random(in: 0 ... 255) }
            let options = (0 ..< Int.random(in: 0 ... 6, using: &generator)).map { _ in
                CoAPOption(
                    .init(rawValue: .random(in: 0 ... 2000, using: &generator)),
                    value: (0 ..< Int.random(in: 0 ... 300, using: &generator)).map { _ in UInt8.random(in: 0 ... 255) }
                )
            }
            let payload = (0 ..< Int.random(in: 0 ... 64, using: &generator)).map { _ in UInt8.random(in: 0 ... 255) }
            let message = CoAPMessage(
                type: type, code: code, messageID: .random(in: 0 ... .max, using: &generator),
                token: token, options: options, payload: payload
            )
            let decoded = try CoAPMessage.decode(message.encode())
            // Decoding yields options sorted by number (stable), which is the canonical form.
            var canonical = message
            canonical.options = message.options.enumerated()
                .sorted { ($0.element.number.rawValue, $0.offset) < ($1.element.number.rawValue, $1.offset) }
                .map(\.element)
            #expect(decoded == canonical)
        }
    }

    // MARK: Encoding errors

    @Test func tokenTooLong() {
        let message = CoAPMessage(type: .confirmable, code: .get, messageID: 1, token: Array(repeating: 1, count: 9))
        #expect(throws: CoAPEncodingError.tokenTooLong(9)) { try message.encode() }
    }

    @Test func emptyMessageWithPayloadIsInvalid() {
        let message = CoAPMessage(type: .acknowledgement, code: .empty, messageID: 1, payload: [1])
        #expect(throws: CoAPEncodingError.invalidEmptyMessage) { try message.encode() }
    }

    @Test func optionValueTooLong() {
        let option = CoAPOption(.uriQuery, value: [UInt8](repeating: 0, count: 65805))
        let message = CoAPMessage(type: .confirmable, code: .get, messageID: 1, options: [option])
        #expect(throws: CoAPEncodingError.optionValueTooLong(number: 15, length: 65805)) { try message.encode() }
    }

    // MARK: Decoding errors (message format errors)

    @Test(arguments: [
        ([UInt8](), CoAPDecodingError.truncatedHeader(length: 0)),
        ([0x40, 0x01, 0x00], .truncatedHeader(length: 3)),
        ([0x80, 0x01, 0x00, 0x01], .unsupportedVersion(2)),
        ([0x00, 0x01, 0x00, 0x01], .unsupportedVersion(0)),
        ([0x49, 0x01, 0x00, 0x01], .invalidTokenLength(9)),
        ([0x4F, 0x01, 0x00, 0x01], .invalidTokenLength(15)),
        ([0x44, 0x01, 0x00, 0x01, 0xAA, 0xBB], .truncatedToken),
        ([0x41, 0x00, 0x00, 0x01, 0xAA], .nonEmptyEmptyMessage),
        ([0x60, 0x00, 0x00, 0x01, 0xFF, 0x01], .nonEmptyEmptyMessage),
        ([0x40, 0x01, 0x00, 0x01, 0xF0], .reservedOptionNibble),
        ([0x40, 0x01, 0x00, 0x01, 0x0F], .reservedOptionNibble),
        ([0x40, 0x01, 0x00, 0x01, 0xD0], .truncatedOption),
        ([0x40, 0x01, 0x00, 0x01, 0xE0, 0x00], .truncatedOption),
        ([0x40, 0x01, 0x00, 0x01, 0x03, 0x61], .truncatedOption),
        ([0x40, 0x01, 0x00, 0x01, 0x0D], .truncatedOption),
        ([0x40, 0x01, 0x00, 0x01, 0xFF], .emptyPayloadAfterMarker),
        // Two maximal deltas: 65804 + 65804 overflows the 16-bit option number space.
        ([0x40, 0x01, 0x00, 0x01, 0xE0, 0xFF, 0xFF, 0xE0, 0xFF, 0xFF], .optionNumberOverflow),
    ])
    func malformed(bytes: [UInt8], error: CoAPDecodingError) {
        #expect(throws: error) { try CoAPMessage.decode(bytes) }
    }

    @Test func fuzzDecodeNeverTraps() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 5000 {
            var bytes = (0 ..< Int.random(in: 0 ... 40, using: &generator)).map { _ in UInt8.random(in: 0 ... 255) }
            if !bytes.isEmpty {
                bytes[0] = (bytes[0] & 0x3F) | 0x40
            } // mostly version 1
            _ = try? CoAPMessage.decode(bytes)
        }
    }

    // MARK: Description

    @Test func descriptionOmitsPayload() {
        var message = CoAPMessage(
            type: .confirmable,
            code: .post,
            messageID: 0x1A2B,
            token: [0x0A],
            payload: [0x41, 0x42]
        )
        message.setURIPath("sys/dev/sync")
        #expect(message.description == "CON 0.02 POST mid=0x1A2B tok=0A /sys/dev/sync [2 B]")
    }

    @Test func codeDescription() {
        #expect(CoAPMessage.Code.content.description == "2.05 Content")
        #expect(CoAPMessage.Code(4, 4).description == "4.04 Not Found")
        #expect(CoAPMessage.Code(7, 31).description == "7.31")
        #expect(CoAPMessage.Code.content.isSuccess)
        #expect(CoAPMessage.Code.get.isRequest)
    }

    @Test func hexHelpers() {
        #expect(Hex.encode([0x00, 0xAB, 0xFF]) == "00ABFF")
        #expect(Hex.decode("00abFF") == [0x00, 0xAB, 0xFF])
        #expect(Hex.decode("ABC") == nil)
        #expect(Hex.decode("GG") == nil)
    }
}
