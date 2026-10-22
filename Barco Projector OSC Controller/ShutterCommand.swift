import Foundation

/// A parsed `/projector/%num/shutter open|close|status` message.
struct ShutterCommand {
    enum Action: String {
        case open
        case close
        case status
    }

    let projectorIndexes: [UInt]
    let action: Action
}

enum ShutterCommandParseResult {
    case command(ShutterCommand, warnings: [String])
    /// The address isn't /projector/…/shutter at all.
    case notAShutterMessage
    /// The address matched but the message can't be used; the reason reads as a sentence fragment.
    case invalid(String)
}

enum ShutterCommandParser {

    /// Accepts:
    ///   /projector/3/shutter open
    ///   /projector/{1,2}/shutter close
    ///   /projector/3/shutter status
    /// The action may be sent as an OSC string argument (QLab sends what you type after the address).
    static func parse(_ message: OSCMessage) -> ShutterCommandParseResult {
        // "/projector/{1,2}/shutter" → ["", "projector", "{1,2}", "shutter"]
        let parts = message.address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].isEmpty,
              parts[1].lowercased() == "projector",
              parts[3].lowercased() == "shutter" else {
            return .notAShutterMessage
        }

        let indexes: [UInt]
        switch FadeCommandParser.parseProjectorIndexes(parts[2]) {
        case .success(let parsed): indexes = parsed
        case .failure(let bad): return .invalid("projector OSC target \"\(bad.text)\" isn't a whole number.")
        }

        let tokens = FadeCommandParser.tokens(from: message.arguments)
        guard let first = tokens.first else {
            return .invalid("it has no action. Add open, close, or status after the address.")
        }
        guard case .word(let word) = first, let action = ShutterCommand.Action(rawValue: word.lowercased()) else {
            return .invalid("shutter action \(first) must be open, close, or status.")
        }

        var warnings: [String] = []
        if tokens.count > 1 {
            warnings.append("Ignored extra arguments in \"\(message)\".")
        }
        return .command(ShutterCommand(projectorIndexes: indexes, action: action), warnings: warnings)
    }
}
