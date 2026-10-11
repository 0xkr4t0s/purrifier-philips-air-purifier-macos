/// Errors thrown when a datagram is not a well-formed CoAP message (RFC 7252 §3).
/// RFC 7252 calls all of these "message format errors": the receiver rejects the
/// message (RST for a CON) or silently drops it.
public enum CoAPDecodingError: Error, Sendable, Hashable {
    case truncatedHeader(length: Int)
    case unsupportedVersion(UInt8)
    /// TKL 9–15 is reserved.
    case invalidTokenLength(UInt8)
    case truncatedToken
    /// An Empty (0.00) message carried bytes after the Message ID.
    case nonEmptyEmptyMessage
    /// Option delta or length nibble 15 outside the 0xFF payload marker.
    case reservedOptionNibble
    case truncatedOption
    case optionNumberOverflow
    /// A payload marker with no payload after it.
    case emptyPayloadAfterMarker
}

public enum CoAPEncodingError: Error, Sendable, Hashable {
    case tokenTooLong(Int)
    case optionValueTooLong(number: UInt16, length: Int)
    /// Empty (0.00) messages must not have a token, options or a payload.
    case invalidEmptyMessage
}

extension CoAPMessage {
    // MARK: Encoding

    /// Serialises the message into a datagram.
    public func encode() throws(CoAPEncodingError) -> [UInt8] {
        guard token.count <= Self.maxTokenLength else {
            throw .tokenTooLong(token.count)
        }
        if code.isEmpty, !token.isEmpty || !options.isEmpty || !payload.isEmpty {
            throw .invalidEmptyMessage
        }

        var out: [UInt8] = []
        out.reserveCapacity(4 + token.count + payload.count + options.count * 4 + 1)
        out.append((Self.version << 6) | (type.rawValue << 4) | UInt8(token.count))
        out.append(code.rawValue)
        out.append(UInt8(messageID >> 8))
        out.append(UInt8(messageID & 0xFF))
        out.append(contentsOf: token)

        // Options must be in ascending order of number; keep repeated options in insertion order.
        let sorted = options.enumerated().sorted {
            ($0.element.number.rawValue, $0.offset) < ($1.element.number.rawValue, $1.offset)
        }
        var previous: UInt16 = 0
        for (_, option) in sorted {
            guard option.value.count <= CoAPOption.maxValueLength else {
                throw .optionValueTooLong(number: option.number.rawValue, length: option.value.count)
            }
            let delta = Int(option.number.rawValue - previous)
            let (deltaNibble, deltaExtended) = Self.extendedField(delta)
            let (lengthNibble, lengthExtended) = Self.extendedField(option.value.count)
            out.append((deltaNibble << 4) | lengthNibble)
            out.append(contentsOf: deltaExtended)
            out.append(contentsOf: lengthExtended)
            out.append(contentsOf: option.value)
            previous = option.number.rawValue
        }

        if !payload.isEmpty {
            out.append(Self.payloadMarker)
            out.append(contentsOf: payload)
        }
        return out
    }

    /// Splits a delta or length into its 4-bit nibble and 0–2 extension bytes (RFC 7252 §3.1).
    ///
    /// - 0...12: the value itself, no extension
    /// - 13...268: nibble 13, one byte holding `value - 13`
    /// - 269...65804: nibble 14, two bytes (big-endian) holding `value - 269`
    static func extendedField(_ value: Int) -> (nibble: UInt8, extended: [UInt8]) {
        switch value {
        case ..<13:
            return (UInt8(value), [])
        case ..<269:
            return (13, [UInt8(value - 13)])
        default:
            let rest = value - 269
            return (14, [UInt8(rest >> 8), UInt8(rest & 0xFF)])
        }
    }

    static let payloadMarker: UInt8 = 0xFF

    // MARK: Decoding

    /// Parses a datagram. Throws rather than guessing on any malformed input; the
    /// parser never reads past the end of `bytes`.
    public static func decode(_ bytes: [UInt8]) throws(CoAPDecodingError) -> CoAPMessage {
        guard bytes.count >= 4 else { throw .truncatedHeader(length: bytes.count) }

        let version = bytes[0] >> 6
        guard version == Self.version else { throw .unsupportedVersion(version) }
        // The 2-bit field can only hold 0...3, so this can't fail.
        let type = MessageType(rawValue: (bytes[0] >> 4) & 0x03) ?? .reset
        let tokenLength = bytes[0] & 0x0F
        guard tokenLength <= maxTokenLength else { throw .invalidTokenLength(tokenLength) }
        let code = Code(rawValue: bytes[1])
        let messageID = UInt16(bytes[2]) << 8 | UInt16(bytes[3])

        if code.isEmpty, tokenLength != 0 || bytes.count > 4 {
            throw .nonEmptyEmptyMessage
        }

        var index = 4
        guard bytes.count >= index + Int(tokenLength) else { throw .truncatedToken }
        let token = Array(bytes[index ..< index + Int(tokenLength)])
        index += Int(tokenLength)

        var options: [CoAPOption] = []
        var payload: [UInt8] = []
        var number = 0
        while index < bytes.count {
            let header = bytes[index]
            index += 1
            if header == payloadMarker {
                guard index < bytes.count else { throw .emptyPayloadAfterMarker }
                payload = Array(bytes[index...])
                break
            }
            let delta = try readExtendedField(nibble: header >> 4, bytes: bytes, index: &index)
            let length = try readExtendedField(nibble: header & 0x0F, bytes: bytes, index: &index)
            number += delta
            guard number <= Int(UInt16.max) else { throw .optionNumberOverflow }
            guard bytes.count - index >= length else { throw .truncatedOption }
            let value = Array(bytes[index ..< index + length])
            index += length
            options.append(CoAPOption(CoAPOption.Number(rawValue: UInt16(number)), value: value))
        }

        return CoAPMessage(
            type: type,
            code: code,
            messageID: messageID,
            token: token,
            options: options,
            payload: payload
        )
    }

    private static func readExtendedField(
        nibble: UInt8,
        bytes: [UInt8],
        index: inout Int
    ) throws(CoAPDecodingError) -> Int {
        switch nibble {
        case 0 ... 12:
            return Int(nibble)
        case 13:
            guard index < bytes.count else { throw .truncatedOption }
            defer { index += 1 }
            return Int(bytes[index]) + 13
        case 14:
            guard index + 1 < bytes.count else { throw .truncatedOption }
            defer { index += 2 }
            return (Int(bytes[index]) << 8 | Int(bytes[index + 1])) + 269
        default:
            throw .reservedOptionNibble
        }
    }
}
