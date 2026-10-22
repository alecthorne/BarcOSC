import Foundation

/// The contents of a saved settings file (JSON):
///
///     {
///       "defaultFadeTime" : 4.9,
///       "formatVersion" : 1,
///       "logProjectorCommands" : false,
///       "logReceivedOSC" : false,
///       "projectors" : [
///         { "index" : 1, "ipAddress" : "10.10.3.5", "name" : "FOH SL - BARCO-1" }
///       ]
///     }
struct SettingsFile: Encodable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var defaultFadeTime: Float
    /// Optional when reading, so hand-written files can leave them out (the current setting is kept).
    var logReceivedOSC: Bool?
    var logProjectorCommands: Bool?
    var projectors: [Projector]

    struct InvalidFile: Error {
        let messages: [String]
    }

    /// What's read from disk, before checking. The index is read as any number, and the name may be
    /// left out, so mistakes in hand-edited files get the same messages as the Add Projector form.
    private struct RawFile: Decodable {
        struct RawProjector: Decodable {
            let index: Double
            let name: String?
            let ipAddress: String
        }
        let formatVersion: Int
        let defaultFadeTime: Float
        let logReceivedOSC: Bool?
        let logProjectorCommands: Bool?
        let projectors: [RawProjector]
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decodes and checks a settings file. On success the projectors are normalized and sorted,
    /// exactly as if they had been added with Add Projector. On failure, lists every problem found.
    static func decode(_ data: Data) -> Result<SettingsFile, InvalidFile> {
        // Check the version first, so a file from a newer app gets a clear message.
        struct Header: Decodable { let formatVersion: Int }
        if let header = try? JSONDecoder().decode(Header.self, from: data),
           header.formatVersion > currentFormatVersion {
            return .failure(InvalidFile(messages: [
                "This settings file was made by a newer version of the app (format \(header.formatVersion)). This version can read format \(currentFormatVersion)."
            ]))
        }

        let file: RawFile
        do {
            file = try JSONDecoder().decode(RawFile.self, from: data)
        } catch let error as DecodingError {
            return .failure(InvalidFile(messages: [describe(error)]))
        } catch {
            return .failure(InvalidFile(messages: ["The file couldn't be read: \(error.localizedDescription)"]))
        }

        var messages: [String] = []
        if !file.defaultFadeTime.isFinite || file.defaultFadeTime < 0 {
            messages.append("\"defaultFadeTime\" is \(file.defaultFadeTime). It must be a number of seconds that is 0 or greater.")
        }

        // Run every projector through the same checks as Add Projector, including duplicates.
        var accepted: [Projector] = []
        for (position, projector) in file.projectors.enumerated() {
            // A whole number is passed on as digits ("3"); anything else ("-1.0", "2.5") fails validation.
            let index = projector.index
            let isWholeUInt = index >= 0 && index < 0x1p64 && index == index.rounded()
            let indexText = isWholeUInt ? String(UInt(index)) : String(index)
            switch ProjectorValidator.validate(indexText: indexText,
                                               name: projector.name ?? "",
                                               ipText: projector.ipAddress,
                                               existing: accepted) {
            case .success(let valid):
                accepted.append(valid)
            case .failure(let failure):
                messages += failure.messages.map { "Projector \(position + 1) in the file: \($0)" }
            }
        }

        guard messages.isEmpty else { return .failure(InvalidFile(messages: messages)) }
        return .success(SettingsFile(formatVersion: file.formatVersion,
                                     defaultFadeTime: file.defaultFadeTime,
                                     logReceivedOSC: file.logReceivedOSC,
                                     logProjectorCommands: file.logProjectorCommands,
                                     projectors: accepted.sorted { $0.index < $1.index }))
    }

    /// Turns a DecodingError into a sentence that points at the problem, e.g.
    /// `"projectors" → item 2 → "ipAddress" is missing.`
    private static func describe(_ error: DecodingError) -> String {
        func location(_ path: [CodingKey]) -> String {
            path.map { key in key.intValue.map { "item \($0 + 1)" } ?? "\"\(key.stringValue)\"" }
                .joined(separator: " → ")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(location(context.codingPath + [key])) is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(location(context.codingPath)) has the wrong kind of value."
        case .dataCorrupted(let context):
            guard context.codingPath.isEmpty else { return "\(location(context.codingPath)) has an invalid value." }
            if let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String {
                return "The file isn't valid JSON (\(detail))"
            }
            return "The file isn't valid JSON."
        @unknown default:
            return "The file isn't a valid settings file."
        }
    }
}
