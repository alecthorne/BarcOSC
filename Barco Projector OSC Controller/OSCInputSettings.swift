import Foundation

/// Where and from whom the app accepts OSC: the interface and port it listens on,
/// and optionally a list of sender IP addresses.
struct OSCInputSettings: Codable, Equatable {
    /// `interface` value meaning every interface.
    static let allInterfaces = "all"
    /// `interface` value meaning only this Mac (the BSD name of the loopback interface).
    static let loopbackInterface = "lo0"
    static let defaultPort: UInt16 = 9090

    /// `allInterfaces`, `loopbackInterface`, or the BSD name of an interface such as "en0".
    var interface = OSCInputSettings.loopbackInterface
    var port = OSCInputSettings.defaultPort
    /// When true (and not listening on loopback), only `allowedSenders` may send OSC.
    var onlyFromAllowedSenders = false
    /// IPv4 addresses in canonical dotted-quad form.
    var allowedSenders: [String] = []
    /// When true, OSC is accepted only over TCP; UDP messages are dropped (and noted in the Log).
    var tcpOnly = true

    init() {}

    /// Keys missing from saved data keep their defaults, so settings saved by earlier versions still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OSCInputSettings()
        interface = try container.decodeIfPresent(String.self, forKey: .interface) ?? defaults.interface
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? defaults.port
        onlyFromAllowedSenders = try container.decodeIfPresent(Bool.self, forKey: .onlyFromAllowedSenders) ?? defaults.onlyFromAllowedSenders
        allowedSenders = try container.decodeIfPresent([String].self, forKey: .allowedSenders) ?? defaults.allowedSenders
        tcpOnly = try container.decodeIfPresent(Bool.self, forKey: .tcpOnly) ?? defaults.tcpOnly
    }

    /// e.g. "TCP" or "UDP or TCP", for telling the user how to send.
    var protocolsText: String { tcpOnly ? "TCP" : "UDP or TCP" }

    var isLoopback: Bool { interface == Self.loopbackInterface }
    var isAllInterfaces: Bool { interface == Self.allInterfaces }

    /// The senders to filter on, or nil to accept any sender.
    var senderFilter: Set<String>? {
        guard !isLoopback, onlyFromAllowedSenders else { return nil }
        return Set(allowedSenders)
    }

    var allowedSendersText: String { allowedSenders.joined(separator: ", ") }

    /// Parses a port from 1 to 65535: digits only.
    static func parsePort(_ raw: String) -> UInt16? {
        guard let value = ProjectorValidator.parseIndex(raw), (1...UInt(UInt16.max)).contains(value) else { return nil }
        return UInt16(value)
    }

    /// Splits text on commas and white space and normalizes each IPv4 address, dropping duplicates.
    /// Returns the addresses, and the entries that aren't valid addresses.
    static func parseAllowedSenders(_ raw: String) -> (addresses: [String], invalid: [String]) {
        var addresses: [String] = []
        var invalid: [String] = []
        for entry in raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            if let address = ProjectorValidator.normalizedIPv4(String(entry)) {
                if !addresses.contains(address) { addresses.append(address) }
            } else {
                invalid.append(String(entry))
            }
        }
        return (addresses, invalid)
    }

    /// The message shown when `parseAllowedSenders` finds invalid entries.
    static func invalidSendersMessage(_ invalid: [String]) -> String {
        let quoted = invalid.map { "\"\($0)\"" }
        let subject = quoted.count == 1
            ? "\(quoted[0]) isn't a complete IPv4 address."
            : "\(quoted.joined(separator: ", ")) aren't complete IPv4 addresses."
        return "\(subject) Enter one or more addresses separated by commas, for example 10.10.3.20, 10.10.3.21."
    }
}
