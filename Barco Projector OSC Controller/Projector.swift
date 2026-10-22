import Foundation

/// One projector in the list.
struct Projector: Identifiable, Codable, Hashable {
    var index: UInt
    var name: String
    var ipAddress: String

    var id: UInt { index }

    /// e.g. `Projector 3 "Stage Left" (192.168.1.53)`
    var displayName: String {
        name.isEmpty
            ? "Projector \(index) (\(ipAddress))"
            : "Projector \(index) \"\(name)\" (\(ipAddress))"
    }
}

struct ProjectorValidationError: Error {
    let messages: [String]
}

enum ProjectorValidator {

    /// Parses an unsigned whole number: digits only, no sign, decimal point or spaces.
    static func parseIndex(_ raw: String) -> UInt? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return UInt(text)   // nil if it overflows UInt
    }

    /// Returns the address in canonical dotted-quad form, or nil if it isn't a complete IPv4 address.
    /// Rejects leading zeros ("010") because some software reads them as octal.
    static func normalizedIPv4(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets.map(String.init).joined(separator: ".")
    }

    static func validate(indexText: String,
                         name: String,
                         ipText: String,
                         existing: [Projector]) -> Result<Projector, ProjectorValidationError> {
        var messages: [String] = []
        let trimmedIndex = indexText.trimmingCharacters(in: .whitespaces)
        let trimmedIP = ipText.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        var index: UInt?
        if trimmedIndex.isEmpty {
            messages.append("An OSC target number is required. Enter a whole number such as 1.")
        } else if let parsed = parseIndex(trimmedIndex) {
            if let clash = existing.first(where: { $0.index == parsed }) {
                messages.append("OSC target number \(parsed) is already used by \(clash.displayName). Each projector needs a unique number.")
            } else {
                index = parsed
            }
        } else {
            messages.append("OSC target number \"\(trimmedIndex)\" isn't valid. Use a whole number from 0 to \(UInt.max) with no sign, decimal point, or spaces.")
        }

        var ip: String?
        if trimmedIP.isEmpty {
            messages.append("An IP address is required, for example 192.168.1.50.")
        } else if let normalized = normalizedIPv4(trimmedIP) {
            if let clash = existing.first(where: { $0.ipAddress == normalized }) {
                messages.append("IP address \(normalized) is already used by \(clash.displayName). Each projector needs a unique IP address.")
            } else {
                ip = normalized
            }
        } else {
            messages.append("IP address \"\(trimmedIP)\" isn't a complete IPv4 address. Use four numbers from 0 to 255 separated by periods, without leading zeros, for example 192.168.1.50.")
        }

        if messages.isEmpty, let index, let ip {
            return .success(Projector(index: index, name: trimmedName, ipAddress: ip))
        }
        return .failure(ProjectorValidationError(messages: messages))
    }
}
