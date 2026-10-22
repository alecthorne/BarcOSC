import Foundation

/// A parsed `/projector/%num/power on|off|status` message.
struct PowerCommand {
    enum Action: String {
        case on
        case off
        case status
    }

    let projectorIndexes: [UInt]
    let action: Action
}

enum PowerCommandParseResult {
    case command(PowerCommand, warnings: [String])
    /// The address isn't /projector/…/power at all.
    case notAPowerMessage
    /// The address matched but the message can't be used; the reason reads as a sentence fragment.
    case invalid(String)
}

enum PowerCommandParser {

    /// Accepts:
    ///   /projector/3/power on
    ///   /projector/{1,2}/power off
    ///   /projector/3/power status
    static func parse(_ message: OSCMessage) -> PowerCommandParseResult {
        // "/projector/{1,2}/power" → ["", "projector", "{1,2}", "power"]
        let parts = message.address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].isEmpty,
              parts[1].lowercased() == "projector",
              parts[3].lowercased() == "power" else {
            return .notAPowerMessage
        }

        let indexes: [UInt]
        switch FadeCommandParser.parseProjectorIndexes(parts[2]) {
        case .success(let parsed): indexes = parsed
        case .failure(let bad): return .invalid("projector OSC target \"\(bad.text)\" isn't a whole number.")
        }

        let tokens = FadeCommandParser.tokens(from: message.arguments)
        guard let first = tokens.first else {
            return .invalid("it has no action. Add on, off, or status after the address.")
        }
        guard case .word(let word) = first, let action = PowerCommand.Action(rawValue: word.lowercased()) else {
            return .invalid("power action \(first) must be on, off, or status.")
        }

        var warnings: [String] = []
        if tokens.count > 1 {
            warnings.append("Ignored extra arguments in \"\(message)\".")
        }
        return .command(PowerCommand(projectorIndexes: indexes, action: action), warnings: warnings)
    }
}
