import Foundation

/// A parsed `/projector/%num/intensity %value` or `/projector/%num/intensity status` message.
struct IntensityCommand {
    enum Action {
        /// Whole-number laser power, 0–100.
        case set(Int)
        case status
    }

    let projectorIndexes: [UInt]
    let action: Action
}

enum IntensityCommandParseResult {
    case command(IntensityCommand, warnings: [String])
    /// The address isn't /projector/…/intensity at all.
    case notAnIntensityMessage
    /// The address matched but the message can't be used; the reason reads as a sentence fragment.
    case invalid(String)
}

enum IntensityCommandParser {

    /// Accepts:
    ///   /projector/3/intensity 50
    ///   /projector/{1,2}/intensity 72.6   (rounded to 73)
    ///   /projector/3/intensity 140        (limited to 100)
    ///   /projector/3/intensity status
    /// The value may be an OSC number or a string.
    static func parse(_ message: OSCMessage, knownIndexes: [UInt]) -> IntensityCommandParseResult {
        // "/projector/{1,2}/intensity" → ["", "projector", "{1,2}", "intensity"]
        let parts = message.address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].isEmpty,
              parts[1].lowercased() == "projector",
              parts[3].lowercased() == "intensity" else {
            return .notAnIntensityMessage
        }

        let indexes: [UInt]
        switch FadeCommandParser.parseProjectorIndexes(parts[2], knownIndexes: knownIndexes) {
        case .success(let parsed): indexes = parsed
        case .failure(let bad): return .invalid(bad.reason)
        }

        let tokens = FadeCommandParser.tokens(from: message.arguments)
        guard let first = tokens.first else {
            return .invalid("it has no intensity. Add a number from 0 to 100, or status, after the address.")
        }

        var warnings: [String] = []
        if tokens.count > 1 {
            warnings.append("Ignored extra arguments in \"\(message)\".")
        }

        switch first {
        case .word(let word) where word.caseInsensitiveCompare("status") == .orderedSame:
            return .command(IntensityCommand(projectorIndexes: indexes, action: .status), warnings: warnings)
        case .number(let value) where !value.isNaN:
            // Limit to 0–100 before rounding, so huge or infinite values can't overflow Int.
            let intensity = Int(min(100, max(0, value)).rounded())
            if Float(intensity) != value {
                warnings.insert("Intensity \(value) in \"\(message)\" isn't a whole number from 0 to 100. Using \(intensity) instead.", at: 0)
            }
            return .command(IntensityCommand(projectorIndexes: indexes, action: .set(intensity)), warnings: warnings)
        default:
            return .invalid("intensity \(first) must be a number from 0 to 100, or status.")
        }
    }
}
