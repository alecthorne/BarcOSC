import Foundation

/// A parsed `/projector/%num/fade %dir %time` message.
struct FadeCommand {
    let projectorIndexes: [UInt]
    let endIntensity: Float
    /// nil means "use defaultFadeTime".
    let fadeTime: Float?
}

enum FadeCommandParseResult {
    case command(FadeCommand, warnings: [String])
    /// The address isn't /projector/…/fade at all.
    case notAFadeMessage
    /// The address matched but the message can't be used; the reason reads as a sentence fragment.
    case invalid(String)
}

enum FadeCommandParser {

    /// Accepts:
    ///   /projector/3/fade up
    ///   /projector/{1,2,5}/fade down 2.5
    ///   /projector/4/fade 42.5 10
    /// Arguments may be OSC numbers or strings (QLab sends whichever you type).
    static func parse(_ message: OSCMessage) -> FadeCommandParseResult {
        // "/projector/{1,2}/fade" → ["", "projector", "{1,2}", "fade"]
        let parts = message.address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].isEmpty,
              parts[1].lowercased() == "projector",
              parts[3].lowercased() == "fade" else {
            return .notAFadeMessage
        }

        let indexes: [UInt]
        switch parseProjectorIndexes(parts[2]) {
        case .success(let parsed): indexes = parsed
        case .failure(let bad): return .invalid("projector OSC target \"\(bad.text)\" isn't a whole number.")
        }

        let tokens = tokens(from: message.arguments)

        // %dir → endIntensity
        guard let first = tokens.first else {
            return .invalid("it has no direction. Add up, down, or an intensity from 0 to 100 after the address.")
        }
        let endIntensity: Float
        switch first {
        case .word(let word) where word.caseInsensitiveCompare("up") == .orderedSame:
            endIntensity = 100
        case .word(let word) where word.caseInsensitiveCompare("down") == .orderedSame:
            endIntensity = 0
        case .word(let word):
            return .invalid("direction \"\(word)\" must be up, down, or a number from 0 to 100.")
        case .number(let value):
            guard value.isFinite, value >= 0, value <= 100 else {
                return .invalid("intensity \(value) is outside the allowed range of 0 to 100.")
            }
            endIntensity = value
        }

        // %time → fadeTime (optional, must be >= 0; 0 is a snap)
        var fadeTime: Float?
        var warnings: [String] = []
        if tokens.count >= 2 {
            if case .number(let value) = tokens[1], value.isFinite, value >= 0 {
                fadeTime = value
            } else {
                warnings.append("Fade time \(tokens[1]) in \"\(message)\" must be a number that is 0 or greater. Using the Default Fade Time instead.")
            }
        }
        if tokens.count > 2 {
            warnings.append("Ignored extra arguments in \"\(message)\".")
        }

        return .command(FadeCommand(projectorIndexes: indexes, endIntensity: endIntensity, fadeTime: fadeTime),
                        warnings: warnings)
    }

    struct InvalidProjectorIndex: Error {
        let text: String
    }

    /// Parses %num: a single index or a brace-enclosed, comma-separated list. Duplicates are dropped.
    /// Shared with the other /projector/%num/… commands.
    static func parseProjectorIndexes(_ token: Substring) -> Result<[UInt], InvalidProjectorIndex> {
        var indexToken = token.trimmingCharacters(in: .whitespaces)
        let isList = indexToken.hasPrefix("{") && indexToken.hasSuffix("}")
        if isList { indexToken = String(indexToken.dropFirst().dropLast()) }
        let items = isList
            ? indexToken.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            : [indexToken]
        var indexes: [UInt] = []
        for item in items {
            let text = item.trimmingCharacters(in: .whitespaces)
            guard let index = ProjectorValidator.parseIndex(text) else {
                return .failure(InvalidProjectorIndex(text: text))
            }
            if !indexes.contains(index) { indexes.append(index) }
        }
        return .success(indexes)
    }

    enum Token: CustomStringConvertible {
        case number(Float)
        case word(String)

        var description: String {
            switch self {
            case .number(let value): return "\(value)"
            case .word(let word): return "\"\(word)\""
            }
        }
    }

    /// Flattens OSC arguments into tokens. String arguments are split on whitespace,
    /// so "up 3" sent as one string works the same as two separate arguments.
    static func tokens(from arguments: [OSCArgument]) -> [Token] {
        var result: [Token] = []
        for argument in arguments {
            switch argument {
            case .int32(let value): result.append(.number(Float(value)))
            case .int64(let value): result.append(.number(Float(value)))
            case .float32(let value): result.append(.number(value))
            case .double(let value): result.append(.number(Float(value)))
            case .string(let string):
                for piece in string.split(whereSeparator: { $0.isWhitespace }) {
                    let text = String(piece)
                    if let value = Float(text) { result.append(.number(value)) } else { result.append(.word(text)) }
                }
            default:
                result.append(.word(argument.description))
            }
        }
        return result
    }
}
