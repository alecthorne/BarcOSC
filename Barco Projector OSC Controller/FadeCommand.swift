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
    /// 3 hours. Longer times are refused everywhere a fade time is entered, partly because
    /// absurd values (e.g. 1e21) overflow Duration and would crash the fade.
    static let maximumFadeTime: Float = 3 * 60 * 60

    /// True for a usable fade time: a number from 0 to `maximumFadeTime` seconds.
    static func isValidFadeTime(_ value: Float) -> Bool {
        value.isFinite && value >= 0 && value <= maximumFadeTime
    }

    /// e.g. "10800 seconds (3 hours)", for messages.
    static var maximumFadeTimeText: String { "\(maximumFadeTime.formatted()) seconds (3 hours)" }

    /// Accepts:
    ///   /projector/3/fade up
    ///   /projector/{1,2,5}/fade down 2.5
    ///   /projector/4/fade 42.5 10
    ///   /projector/*/fade down        (every projector in `knownIndexes`)
    /// Arguments may be OSC numbers or strings (QLab sends whichever you type).
    static func parse(_ message: OSCMessage, knownIndexes: [UInt]) -> FadeCommandParseResult {
        // "/projector/{1,2}/fade" → ["", "projector", "{1,2}", "fade"]
        let parts = message.address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].isEmpty,
              parts[1].lowercased() == "projector",
              parts[3].lowercased() == "fade" else {
            return .notAFadeMessage
        }

        let indexes: [UInt]
        switch parseProjectorIndexes(parts[2], knownIndexes: knownIndexes) {
        case .success(let parsed): indexes = parsed
        case .failure(let bad): return .invalid(bad.reason)
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

        // %time → fadeTime (optional, 0 to maximumFadeTime; 0 is a snap)
        var fadeTime: Float?
        var warnings: [String] = []
        if tokens.count >= 2 {
            if case .number(let value) = tokens[1], isValidFadeTime(value) {
                fadeTime = value
            } else {
                warnings.append("Fade time \(tokens[1]) in \"\(message)\" must be a number of seconds from 0 to \(maximumFadeTimeText). Using the Default Fade Time instead.")
            }
        }
        if tokens.count > 2 {
            warnings.append("Ignored extra arguments in \"\(message)\".")
        }

        return .command(FadeCommand(projectorIndexes: indexes, endIntensity: endIntensity, fadeTime: fadeTime),
                        warnings: warnings)
    }

    struct InvalidProjectorIndex: Error {
        /// Reads as a sentence fragment, e.g. `projector OSC target "x" isn't a whole number.`
        let reason: String
    }

    /// Parses %num: a single index, a brace-enclosed, comma-separated list, or an OSC address pattern
    /// such as `*`, `[1-4]` or `1?`. Duplicates are dropped. Shared with the other /projector/%num/… commands.
    ///
    /// A number or list is used as written, so a number that isn't in the projector list gets its own
    /// error. A pattern is matched against `knownIndexes` and must match at least one.
    static func parseProjectorIndexes(_ token: Substring, knownIndexes: [UInt]) -> Result<[UInt], InvalidProjectorIndex> {
        let pattern = token.trimmingCharacters(in: .whitespaces)
        if OSCAddressPattern.hasWildcards(pattern) {
            if let problem = OSCAddressPattern.problem(in: pattern) {
                return .failure(InvalidProjectorIndex(reason: "projector OSC target pattern \"\(pattern)\" isn't valid: \(problem)."))
            }
            let matched = knownIndexes.sorted().filter { OSCAddressPattern.matches(pattern, String($0)) }
            guard !matched.isEmpty else {
                return .failure(InvalidProjectorIndex(reason: "projector OSC target pattern \"\(pattern)\" doesn't match any projector in the projector list."))
            }
            return .success(matched)
        }

        var indexToken = pattern
        let isList = indexToken.hasPrefix("{") && indexToken.hasSuffix("}")
        if isList { indexToken = String(indexToken.dropFirst().dropLast()) }
        let items = isList
            ? indexToken.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            : [indexToken]
        var indexes: [UInt] = []
        for item in items {
            let text = item.trimmingCharacters(in: .whitespaces)
            guard let index = ProjectorValidator.parseIndex(text) else {
                return .failure(InvalidProjectorIndex(reason: "projector OSC target \"\(text)\" isn't a whole number."))
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
