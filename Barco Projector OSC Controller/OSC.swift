import Foundation

// MARK: - OSC message model

enum OSCArgument: CustomStringConvertible {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case timeTag(UInt64)
    case bool(Bool)
    case null
    case impulse
    case unsupported(Character)

    var description: String {
        switch self {
        case .int32(let value): return "\(value)"
        case .float32(let value): return "\(value)"
        case .string(let value): return value.contains(" ") ? "\"\(value)\"" : value
        case .blob(let data): return "<blob \(data.count) bytes>"
        case .int64(let value): return "\(value)"
        case .double(let value): return "\(value)"
        case .timeTag(let value): return "<timetag \(value)>"
        case .bool(let value): return value ? "true" : "false"
        case .null: return "nil"
        case .impulse: return "<impulse>"
        case .unsupported(let tag): return "<unsupported type '\(tag)'>"
        }
    }
}

struct OSCMessage: CustomStringConvertible {
    let address: String
    let arguments: [OSCArgument]

    var description: String {
        ([address] + arguments.map(\.description)).joined(separator: " ")
    }
}

enum OSCParseError: Error, CustomStringConvertible {
    case empty
    case notOSC
    case malformed(String)

    var description: String {
        switch self {
        case .empty: return "empty packet"
        case .notOSC: return "not an OSC message or bundle"
        case .malformed(let reason): return reason
        }
    }
}

// MARK: - Parser (OSC 1.0 / 1.1)

enum OSCParser {
    /// Parses one OSC packet (a message or a bundle) into messages.
    static func parse(_ data: Data) throws -> [OSCMessage] {
        try parse(bytes: [UInt8](data), depth: 0)
    }

    private static func parse(bytes: [UInt8], depth: Int) throws -> [OSCMessage] {
        guard let first = bytes.first else { throw OSCParseError.empty }
        guard depth < 8 else { throw OSCParseError.malformed("bundles are nested too deeply") }
        var reader = ByteReader(bytes: bytes)

        switch first {
        case UInt8(ascii: "#"):
            guard try reader.readString() == "#bundle" else { throw OSCParseError.notOSC }
            _ = try reader.readUInt64()   // time tag; QLab doesn't schedule, so it's ignored
            var messages: [OSCMessage] = []
            while !reader.isAtEnd {
                let size = Int(try reader.readInt32())
                let element = try reader.readBytes(size)
                if !element.isEmpty { messages += try parse(bytes: element, depth: depth + 1) }
            }
            return messages

        case UInt8(ascii: "/"):
            let address = try reader.readString()
            var arguments: [OSCArgument] = []
            if !reader.isAtEnd {
                let typeTags = try reader.readString()
                guard typeTags.hasPrefix(",") else { throw OSCParseError.malformed("missing type tag string") }
                for tag in typeTags.dropFirst() {
                    switch tag {
                    case "i": arguments.append(.int32(try reader.readInt32()))
                    case "f": arguments.append(.float32(Float(bitPattern: try reader.readUInt32())))
                    case "s", "S": arguments.append(.string(try reader.readString()))
                    case "b": arguments.append(.blob(Data(try reader.readBlob())))
                    case "h": arguments.append(.int64(Int64(bitPattern: try reader.readUInt64())))
                    case "d": arguments.append(.double(Double(bitPattern: try reader.readUInt64())))
                    case "t": arguments.append(.timeTag(try reader.readUInt64()))
                    case "c":
                        let scalar = UnicodeScalar(UInt8(truncatingIfNeeded: try reader.readInt32()))
                        arguments.append(.string(String(Character(scalar))))
                    case "r", "m":
                        _ = try reader.readUInt32()
                        arguments.append(.unsupported(tag))
                    case "T": arguments.append(.bool(true))
                    case "F": arguments.append(.bool(false))
                    case "N": arguments.append(.null)
                    case "I": arguments.append(.impulse)
                    case "[", "]": continue   // array markers: flatten
                    default: throw OSCParseError.malformed("unknown type tag '\(tag)'")
                    }
                }
            }
            return [OSCMessage(address: address, arguments: arguments)]

        default:
            throw OSCParseError.notOSC
        }
    }
}

// MARK: - Address pattern matching (OSC 1.0)

/// Matches one part of an OSC address pattern (the text between two slashes) against a name:
///   `?` any one character, `*` any run of characters, `[1-3]` / `[135]` one listed character,
///   `[!4]` one character not listed, `{1,12}` any of the comma-separated strings.
enum OSCAddressPattern {
    /// True if `part` uses any pattern syntax other than a plain `{a,b}` list.
    static func hasWildcards(_ part: some StringProtocol) -> Bool {
        part.contains { "*?[]".contains($0) }
    }

    /// Returns a reason (a sentence fragment) if the pattern's brackets or braces don't pair up.
    static func problem(in pattern: String) -> String? {
        var open: Character?
        for character in pattern {
            switch character {
            case "[", "{":
                if let open { return "it has \"\(character)\" inside \"\(open)…\"" }
                open = character
            case "]", "}":
                let expected: Character = character == "]" ? "[" : "{"
                guard open == expected else { return "it has \"\(character)\" without a matching \"\(expected)\"" }
                open = nil
            default:
                break
            }
        }
        if let open { return "it has \"\(open)\" without a closing \"\(open == "[" ? "]" : "}")\"" }
        return nil
    }

    /// Call `problem(in:)` first; a malformed pattern matches nothing.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        matches(Array(pattern)[...], Array(name)[...])
    }

    private static func matches(_ pattern: ArraySlice<Character>, _ name: ArraySlice<Character>) -> Bool {
        guard let first = pattern.first else { return name.isEmpty }
        let rest = pattern.dropFirst()
        switch first {
        case "*":
            var tail = name
            while true {
                if matches(rest, tail) { return true }
                guard !tail.isEmpty else { return false }
                tail = tail.dropFirst()
            }
        case "?":
            return !name.isEmpty && matches(rest, name.dropFirst())
        case "[":
            guard let close = rest.firstIndex(of: "]"), let character = name.first else { return false }
            var set = rest[rest.startIndex..<close]
            let negated = set.first == "!"
            if negated { set = set.dropFirst() }
            return contains(set, character) != negated && matches(pattern[(close + 1)...], name.dropFirst())
        case "{":
            guard let close = rest.firstIndex(of: "}") else { return false }
            let after = pattern[(close + 1)...]
            return rest[rest.startIndex..<close]
                .split(separator: ",", omittingEmptySubsequences: false)
                .contains { matches($0 + after, name) }
        default:
            return name.first == first && matches(rest, name.dropFirst())
        }
    }

    /// Whether a bracket set such as `1-35` (the text between `[` and `]`) contains `character`.
    /// A `-` at the start or end is literal.
    private static func contains(_ set: ArraySlice<Character>, _ character: Character) -> Bool {
        let items = Array(set)
        var i = 0
        while i < items.count {
            if i + 2 < items.count, items[i + 1] == "-" {
                // A backwards range such as 3-1 matches nothing (and would trap as a ClosedRange).
                if items[i] <= items[i + 2], (items[i]...items[i + 2]).contains(character) { return true }
                i += 3
            } else {
                if items[i] == character { return true }
                i += 1
            }
        }
        return false
    }
}

// MARK: - Encoder (OSC 1.1)

enum OSCEncoder {
    /// Encodes one message as an OSC packet. Unsupported arguments are left out.
    static func encode(_ message: OSCMessage) -> Data {
        var typeTags = ","
        var payload: [UInt8] = []
        for argument in message.arguments {
            switch argument {
            case .int32(let value): typeTags += "i"; appendUInt32(UInt32(bitPattern: value), to: &payload)
            case .float32(let value): typeTags += "f"; appendUInt32(value.bitPattern, to: &payload)
            case .string(let value): typeTags += "s"; appendString(value, to: &payload)
            case .blob(let data):
                typeTags += "b"
                appendUInt32(UInt32(data.count), to: &payload)
                payload += data
                payload += [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
            case .int64(let value): typeTags += "h"; appendUInt64(UInt64(bitPattern: value), to: &payload)
            case .double(let value): typeTags += "d"; appendUInt64(value.bitPattern, to: &payload)
            case .timeTag(let value): typeTags += "t"; appendUInt64(value, to: &payload)
            case .bool(let value): typeTags += value ? "T" : "F"
            case .null: typeTags += "N"
            case .impulse: typeTags += "I"
            case .unsupported: break
            }
        }
        var bytes: [UInt8] = []
        appendString(message.address, to: &bytes)
        appendString(typeTags, to: &bytes)
        return Data(bytes + payload)
    }

    /// Null-terminated and padded to a multiple of 4 bytes.
    private static func appendString(_ string: String, to bytes: inout [UInt8]) {
        let utf8 = Array(string.utf8)
        bytes += utf8
        bytes += [UInt8](repeating: 0, count: 4 - utf8.count % 4)
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes += withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        bytes += withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    var isAtEnd: Bool { offset >= bytes.count }

    /// Null-terminated string padded to a multiple of 4 bytes.
    mutating func readString() throws -> String {
        guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else {
            throw OSCParseError.malformed("unterminated string")
        }
        let string = String(decoding: bytes[offset..<end], as: UTF8.self)
        let paddedLength = ((end - offset + 1) + 3) / 4 * 4
        offset = min(bytes.count, offset + paddedLength)   // tolerate senders that skip the last padding
        return string
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else {
            throw OSCParseError.malformed("message is truncated")
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt32() throws -> UInt32 {
        try readBytes(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readUInt64() throws -> UInt64 {
        try readBytes(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func readBlob() throws -> [UInt8] {
        let size = Int(try readInt32())
        let data = try readBytes(size)
        offset = min(bytes.count, offset + (4 - size % 4) % 4)
        return data
    }
}

// MARK: - SLIP framing (OSC 1.1 over TCP, which QLab uses; see OSCStreamDecoder)

struct SLIPDecoder {
    // fileprivate so SLIPEncoder can share them.
    fileprivate static let end: UInt8 = 0xC0
    fileprivate static let escape: UInt8 = 0xDB
    fileprivate static let escapedEnd: UInt8 = 0xDC
    fileprivate static let escapedEscape: UInt8 = 0xDD

    private var frame: [UInt8] = []
    private var escaping = false

    /// Feeds received bytes and returns every frame they complete. Throws if a frame grows past
    /// `OSCStreamDecoder.maximumPacketSize` without ending, so a sender can't grow memory forever.
    mutating func feed(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if escaping {
                escaping = false
                switch byte {
                case Self.escapedEnd: frame.append(Self.end)
                case Self.escapedEscape: frame.append(Self.escape)
                default: frame.append(byte)
                }
                continue
            }
            switch byte {
            case Self.end:
                if !frame.isEmpty {   // double-END framing produces empty frames; skip them
                    frames.append(Data(frame))
                    frame.removeAll(keepingCapacity: true)
                }
            case Self.escape:
                escaping = true
            default:
                frame.append(byte)
            }
            if frame.count > OSCStreamDecoder.maximumPacketSize {
                throw OSCParseError.malformed("a SLIP-framed TCP packet grew past \(OSCStreamDecoder.maximumPacketSize) bytes without ending")
            }
        }
        return frames
    }
}

enum SLIPEncoder {
    /// Frames one packet with double-END SLIP framing.
    static func encode(_ packet: Data) -> Data {
        var frame: [UInt8] = [SLIPDecoder.end]
        for byte in packet {
            switch byte {
            case SLIPDecoder.end: frame += [SLIPDecoder.escape, SLIPDecoder.escapedEnd]
            case SLIPDecoder.escape: frame += [SLIPDecoder.escape, SLIPDecoder.escapedEscape]
            default: frame.append(byte)
            }
        }
        frame.append(SLIPDecoder.end)
        return Data(frame)
    }
}

// MARK: - OSC over TCP (either framing)

/// OSC over TCP is framed one of two ways: SLIP (OSC 1.1, which QLab uses), or a big-endian
/// int32 size before each packet (OSC 1.0). The framing is detected from the first byte received.
struct OSCStreamDecoder {
    enum Framing: String {
        case slip = "SLIP"
        case lengthPrefixed = "size-prefixed"
    }

    /// Larger sizes are treated as a framing error rather than buffered.
    static let maximumPacketSize = 1 << 20

    /// nil until the first byte arrives.
    private(set) var framing: Framing?
    private var slip = SLIPDecoder()
    private var buffer: [UInt8] = []

    /// Feeds received bytes and returns every packet they complete.
    /// Throws if a size prefix is too large to be real, after which the stream can't be trusted.
    mutating func feed(_ data: Data) throws -> [Data] {
        if framing == nil, let first = data.first {
            // A size prefix starts with 0x00 for any packet under 16 MB. A SLIP stream starts with
            // END (0xC0), or with the packet's '/' or '#' when the sender only sends a trailing END.
            framing = first == 0 ? .lengthPrefixed : .slip
        }
        switch framing {
        case .slip:
            return try slip.feed(data)
        case .lengthPrefixed:
            buffer += data
            var packets: [Data] = []
            while buffer.count >= 4 {
                let size = buffer[0..<4].reduce(0) { ($0 << 8) | Int($1) }
                guard size <= Self.maximumPacketSize else {
                    throw OSCParseError.malformed("a size-prefixed TCP packet claims to be \(size) bytes, which is too large")
                }
                guard buffer.count >= 4 + size else { break }   // wait for the rest of the packet
                if size > 0 { packets.append(Data(buffer[4..<(4 + size)])) }
                buffer.removeFirst(4 + size)
            }
            return packets
        case nil:
            return []
        }
    }

    /// Frames a reply the same way the sender frames its packets.
    func encode(_ packet: Data) -> Data {
        switch framing {
        case .lengthPrefixed:
            return Data(withUnsafeBytes(of: UInt32(packet.count).bigEndian, Array.init)) + packet
        case .slip, nil:
            return SLIPEncoder.encode(packet)
        }
    }
}
