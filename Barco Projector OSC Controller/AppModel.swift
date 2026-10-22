import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers

struct AlertInfo {
    let title: String
    let message: String
}

/// App state: the projector list, connections, OSC handling, fades and logs.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    static let oscPort: UInt16 = 9090
    static let fallbackDefaultFadeTime: Float = 4.9

    private enum DefaultsKey {
        static let defaultFadeTime = "defaultFadeTime"
        static let projectors = "projectors"
    }

    // MARK: State shown in the UI

    @Published private(set) var projectors: [Projector] = []
    @Published private(set) var defaultFadeTime: Float = 4.9
    @Published private(set) var connectionsOpen = false
    @Published private(set) var connections: [UInt: ProjectorConnection] = [:]
    @Published private(set) var logText = ""
    @Published private(set) var commandLogText = ""
    @Published var logReceivedOSC = false
    @Published var logProjectorCommands = false
    @Published var alert: AlertInfo?

    // MARK: Internals

    private struct ActiveFade {
        let token: UUID
        let task: Task<Void, Never>
    }

    /// A pending power off for one projector, counting down in a Log line.
    private struct PowerOffCountdown {
        let token: UUID
        let task: Task<Void, Never>
        let logLine: LogLineID
    }

    static let powerOffDelaySeconds = 10

    private let oscServer: OSCServer
    private var fades: [UInt: ActiveFade] = [:]
    private var powerOffCountdowns: [UInt: PowerOffCountdown] = [:]
    private var logLines: [LogLine] = []
    private var nextLogLineID = 1
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private init() {
        oscServer = OSCServer(port: Self.oscPort)

        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.defaultFadeTime) != nil {
            let stored = defaults.float(forKey: DefaultsKey.defaultFadeTime)
            defaultFadeTime = (stored.isFinite && stored >= 0) ? stored : Self.fallbackDefaultFadeTime
        }
        if let data = defaults.data(forKey: DefaultsKey.projectors),
           let saved = try? JSONDecoder().decode([Projector].self, from: data) {
            projectors = saved.sorted { $0.index < $1.index }
        }

        oscServer.onMessage = { [weak self] message, transport, reply in
            self?.handleOSC(message, transport: transport, reply: reply)
        }
        oscServer.onLog = { [weak self] line in
            self?.log(line)
        }
        oscServer.onParseError = { [weak self] problem in
            guard let self, self.logReceivedOSC else { return }
            self.log("ERROR: \(problem)")
        }
    }

    // MARK: - Logs

    /// Identifies a Log line so it can be rewritten later with `updateLog(_:_:)`.
    struct LogLineID: Hashable {
        fileprivate let value: Int
    }

    private struct LogLine {
        let id: LogLineID
        var text: String
    }

    /// Adds a timestamped line to the Log and returns its id.
    @discardableResult
    func log(_ message: String) -> LogLineID {
        let id = LogLineID(value: nextLogLineID)
        nextLogLineID += 1
        let line = LogLine(id: id, text: timestamped(message))
        logLines.append(line)
        logText += line.text
        return id
    }

    /// Replaces a Log line's text (and timestamp) in place. If the Log was cleared since, adds it again.
    func updateLog(_ id: LogLineID, _ message: String) {
        guard let position = logLines.firstIndex(where: { $0.id == id }) else {
            let line = LogLine(id: id, text: timestamped(message))
            logLines.append(line)
            logText += line.text
            return
        }
        logLines[position].text = timestamped(message)
        logText = logLines.map(\.text).joined()
    }

    private func timestamped(_ message: String) -> String {
        "[\(timestampFormatter.string(from: Date()))] \(message)\n"
    }

    func logCommand(_ message: String) {
        commandLogText += "[\(timestampFormatter.string(from: Date()))] \(message)\n"
    }

    func clearLog() {
        logLines.removeAll()
        logText = ""
    }
    func clearCommandLog() { commandLogText = "" }

    /// Shows an alert and posts the same message to the Log.
    func reportError(title: String, message: String) {
        log("ERROR: \(message)")
        alert = AlertInfo(title: title, message: message)
    }

    func saveLog(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Save Log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(suggestedName) \(fileDateFormatter.string(from: Date())).txt"
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    self?.log("Saved log to \(url.path).")
                } catch {
                    self?.reportError(title: "Couldn't Save Log",
                                      message: "Couldn't save the log to \(url.path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Settings file

    /// Saves the projector list, Default Fade Time and log checkboxes to a JSON file the user picks.
    func saveSettings() {
        let settings = SettingsFile(formatVersion: SettingsFile.currentFormatVersion,
                                    defaultFadeTime: defaultFadeTime,
                                    logReceivedOSC: logReceivedOSC,
                                    logProjectorCommands: logProjectorCommands,
                                    projectors: projectors)
        let panel = NSSavePanel()
        panel.title = "Save Settings"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Barco Projector Settings.json"
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    try settings.encoded().write(to: url, options: .atomic)
                    self.log("Saved settings to \(url.path): \(settings.projectors.count) projector(s), Default Fade Time \(settings.defaultFadeTime) seconds.")
                } catch {
                    self.reportError(title: "Couldn't Save Settings",
                                     message: "Couldn't save the settings to \(url.path): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Lets the user pick a settings file, checks it, and (after confirming) replaces the current settings.
    func openSettings() {
        guard !connectionsOpen else {
            reportError(title: "Connections Are Open", message: "Close connections before opening a settings file.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Open Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.loadSettings(from: url)
            }
        }
    }

    private func loadSettings(from url: URL) {
        // Connections could have been opened while the Open panel was up.
        guard !connectionsOpen else {
            reportError(title: "Connections Are Open", message: "Close connections before opening a settings file.")
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            reportError(title: "Couldn't Open Settings",
                        message: "Couldn't read \(url.path): \(error.localizedDescription)")
            return
        }

        let settings: SettingsFile
        switch SettingsFile.decode(data) {
        case .success(let decoded):
            settings = decoded
        case .failure(let invalid):
            for message in invalid.messages { log("ERROR: Open Settings: \(message)") }
            alert = AlertInfo(title: "Couldn't Open Settings",
                              message: "\(url.lastPathComponent) wasn't loaded, and your current settings are unchanged.\n\n"
                                       + invalid.messages.joined(separator: "\n\n"))
            return
        }

        if !projectors.isEmpty {
            let confirm = NSAlert()
            confirm.messageText = "Replace the current projectors?"
            confirm.informativeText = "Opening \(url.lastPathComponent) replaces the \(projectors.count) projector(s) in the list, the Default Fade Time and the log settings with the ones in the file."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        projectors = settings.projectors
        defaultFadeTime = settings.defaultFadeTime
        if let value = settings.logReceivedOSC { logReceivedOSC = value }
        if let value = settings.logProjectorCommands { logProjectorCommands = value }
        saveProjectors()
        saveDefaultFadeTime()
        log("Opened settings from \(url.path): \(projectors.count) projector(s), Default Fade Time \(defaultFadeTimeText) seconds.")
    }

    // MARK: - Default fade time

    var defaultFadeTimeText: String { "\(defaultFadeTime)" }

    /// Validates and stores a new Default Fade Time. Returns false (after alerting and logging) if invalid.
    @discardableResult
    func commitDefaultFadeTime(from text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Float(trimmed), value.isFinite, value >= 0 else {
            let problem = trimmed.isEmpty
                ? "Default Fade Time can't be empty."
                : "\"\(trimmed)\" isn't a valid Default Fade Time."
            reportError(title: "Invalid Default Fade Time",
                        message: "\(problem) Enter a number of seconds that is 0 or greater, for example 4.9. Keeping \(defaultFadeTimeText) seconds.")
            return false
        }
        defaultFadeTime = value
        saveDefaultFadeTime()
        return true
    }

    private func saveDefaultFadeTime() {
        UserDefaults.standard.set(defaultFadeTime, forKey: DefaultsKey.defaultFadeTime)
    }

    // MARK: - Projector list

    /// Validates and adds a projector. Returns nil on success, or an error message to show (already logged).
    func addProjector(indexText: String, name: String, ipText: String) -> String? {
        guard !connectionsOpen else {
            let message = "Close connections before adding projectors."
            log("ERROR: \(message)")
            return message
        }
        switch ProjectorValidator.validate(indexText: indexText, name: name, ipText: ipText, existing: projectors) {
        case .success(let projector):
            projectors.append(projector)
            projectors.sort { $0.index < $1.index }
            saveProjectors()
            log("Added \(projector.displayName).")
            return nil
        case .failure(let failure):
            for message in failure.messages { log("ERROR: Add Projector: \(message)") }
            return failure.messages.joined(separator: "\n\n")
        }
    }

    /// Validates and replaces the projector currently at `originalIndex`.
    /// Returns nil on success, or an error message to show (already logged).
    func updateProjector(originalIndex: UInt, indexText: String, name: String, ipText: String) -> String? {
        guard !connectionsOpen else {
            let message = "Close connections before editing projectors."
            log("ERROR: \(message)")
            return message
        }
        guard let original = projectors.first(where: { $0.index == originalIndex }) else {
            let message = "Projector \(originalIndex) is no longer in the list."
            log("ERROR: Edit Projector: \(message)")
            return message
        }
        // The projector being edited may keep its own number and IP address.
        let others = projectors.filter { $0.index != originalIndex }
        switch ProjectorValidator.validate(indexText: indexText, name: name, ipText: ipText, existing: others) {
        case .success(let projector):
            guard projector != original else { return nil }
            projectors = others + [projector]
            projectors.sort { $0.index < $1.index }
            saveProjectors()
            log("Changed \(original.displayName) to \(projector.displayName).")
            return nil
        case .failure(let failure):
            for message in failure.messages { log("ERROR: Edit Projector: \(message)") }
            return failure.messages.joined(separator: "\n\n")
        }
    }

    func deleteProjector(index: UInt) {
        guard !connectionsOpen else {
            reportError(title: "Connections Are Open", message: "Close connections before deleting projectors.")
            return
        }
        guard let projector = projectors.first(where: { $0.index == index }) else { return }
        projectors.removeAll { $0.index == index }
        saveProjectors()
        log("Deleted \(projector.displayName).")
    }

    private func saveProjectors() {
        if let data = try? JSONEncoder().encode(projectors) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.projectors)
        }
    }

    // MARK: - Connections

    func openConnections() {
        guard !connectionsOpen, !projectors.isEmpty else { return }
        connectionsOpen = true
        log("Opening connections to \(projectors.count) projector(s) on TCP port \(ProjectorConnection.port).")
        for projector in projectors {
            let connection = ProjectorConnection(projector: projector)
            connection.onLog = { [weak self] line in self?.log(line) }
            connection.onTraffic = { [weak self] line in
                guard let self, self.logProjectorCommands else { return }
                self.logCommand(line)
            }
            connections[projector.index] = connection
            connection.open()
        }
        oscServer.start()
    }

    func closeConnections() {
        guard connectionsOpen else { return }
        cancelAllFades()
        cancelAllPowerOffCountdowns()
        oscServer.stop()
        for connection in connections.values { connection.close() }
        connections.removeAll()
        connectionsOpen = false
        log("Closed all projector connections and stopped listening for OSC.")
    }

    /// Called when the app quits.
    func prepareForQuit() {
        saveDefaultFadeTime()
        closeConnections()
    }

    // MARK: - OSC

    private func handleOSC(_ message: OSCMessage, transport: OSCServer.Transport, reply: @escaping OSCServer.Reply) {
        if logReceivedOSC { log("OSC received (\(transport.rawValue)): \(message)") }

        switch ShutterCommandParser.parse(message) {
        case .notAShutterMessage:
            break   // try the fade command below
        case .invalid(let reason):
            if logReceivedOSC { log("ERROR: Ignored OSC message \"\(message)\" because \(reason)") }
            return
        case .command(let command, let warnings):
            if logReceivedOSC { for warning in warnings { log("WARNING: \(warning)") } }
            runShutterCommand(command, transport: transport, reply: reply)
            return
        }

        switch IntensityCommandParser.parse(message) {
        case .notAnIntensityMessage:
            break   // try the fade command below
        case .invalid(let reason):
            if logReceivedOSC { log("ERROR: Ignored OSC message \"\(message)\" because \(reason)") }
            return
        case .command(let command, let warnings):
            if logReceivedOSC { for warning in warnings { log("WARNING: \(warning)") } }
            runIntensityCommand(command, transport: transport, reply: reply)
            return
        }

        switch PowerCommandParser.parse(message) {
        case .notAPowerMessage:
            break   // try the fade command below
        case .invalid(let reason):
            if logReceivedOSC { log("ERROR: Ignored OSC message \"\(message)\" because \(reason)") }
            return
        case .command(let command, let warnings):
            if logReceivedOSC { for warning in warnings { log("WARNING: \(warning)") } }
            runPowerCommand(command, transport: transport, reply: reply)
            return
        }

        switch FadeCommandParser.parse(message) {
        case .notAFadeMessage:
            if logReceivedOSC {
                log("ERROR: Ignored OSC message with unrecognized address \(message.address). Expected /projector/{index}/fade, /projector/{index}/intensity, /projector/{index}/shutter, or /projector/{index}/power.")
            }
        case .invalid(let reason):
            if logReceivedOSC { log("ERROR: Ignored OSC message \"\(message)\" because \(reason)") }
        case .command(let command, let warnings):
            if logReceivedOSC { for warning in warnings { log("WARNING: \(warning)") } }
            startFade(command)
        }
    }

    // MARK: - Shutter

    private func runShutterCommand(_ command: ShutterCommand,
                                   transport: OSCServer.Transport,
                                   reply: @escaping OSCServer.Reply) {
        for index in command.projectorIndexes {
            let connection = connections[index]
            switch command.action {
            case .open, .close:
                guard let connection else {
                    log("ERROR: An OSC shutter \(command.action.rawValue) targets projector \(index), which isn't in the projector list.")
                    continue
                }
                if !connection.setShutter(open: command.action == .open) {
                    log("ERROR: Can't \(command.action.rawValue) the shutter of \(connection.label) because it isn't connected.")
                }
            case .status:
                // Replies e.g. /projector/3/shutter/status "open" (or "closed", …).
                replyWithStatus(index: index, connection: connection, command: "shutter", what: "shutter state",
                                transport: transport, reply: reply) { connection in
                    let position = try await connection.getStringProperty(ProjectorConnection.shutterPositionProperty)
                    return .string(position.lowercased())
                }
            }
        }
    }

    // MARK: - Intensity

    private func runIntensityCommand(_ command: IntensityCommand,
                                     transport: OSCServer.Transport,
                                     reply: @escaping OSCServer.Reply) {
        for index in command.projectorIndexes {
            let connection = connections[index]
            switch command.action {
            case .set(let intensity):
                guard let connection else {
                    log("ERROR: An OSC intensity command targets projector \(index), which isn't in the projector list.")
                    continue
                }
                // Set the laser power immediately, replacing any fade running on the same projector.
                fades[index]?.task.cancel()
                fades[index] = nil
                connection.discardQueuedLaserPower()
                if !connection.setLaserPower(intensity) {
                    log("ERROR: Can't set the intensity of \(connection.label) because it isn't connected.")
                }
            case .status:
                // Replies e.g. /projector/3/intensity/status 72.0
                replyWithStatus(index: index, connection: connection, command: "intensity", what: "laser power",
                                transport: transport, reply: reply) { connection in
                    let power = try await connection.getNumberProperty(ProjectorConnection.laserPowerProperty)
                    return .float32(Float(power))
                }
            }
        }
    }

    // MARK: - Power

    private func runPowerCommand(_ command: PowerCommand,
                                 transport: OSCServer.Transport,
                                 reply: @escaping OSCServer.Reply) {
        for index in command.projectorIndexes {
            let connection = connections[index]
            switch command.action {
            case .on:
                // Power on cancels a pending power off, then powers on (harmless if already on).
                if let countdown = powerOffCountdowns.removeValue(forKey: index) {
                    countdown.task.cancel()
                    updateLog(countdown.logLine, "Projector \(index) power off cancelled.")
                }
                guard let connection else {
                    log("ERROR: An OSC power on targets projector \(index), which isn't in the projector list.")
                    continue
                }
                if !connection.powerOn() {
                    log("ERROR: Can't power on \(connection.label) because it isn't connected.")
                }
            case .off:
                guard let connection else {
                    log("ERROR: An OSC power off targets projector \(index), which isn't in the projector list.")
                    continue
                }
                startPowerOffCountdown(index: index, connection: connection)
            case .status:
                // Replies e.g. /projector/3/power/status "on" (or "standby", "deconditioning", …).
                replyWithStatus(index: index, connection: connection, command: "power", what: "power state",
                                transport: transport, reply: reply) { connection in
                    let state = try await connection.getStringProperty(ProjectorConnection.systemStateProperty)
                    return .string(state.lowercased())
                }
            }
        }
    }

    /// Counts down in one Log line, rewriting it each second, then powers the projector off
    /// and reports the result in the same line. A power on command cancels it.
    private func startPowerOffCountdown(index: UInt, connection: ProjectorConnection) {
        guard powerOffCountdowns[index] == nil else {
            log("Projector \(index) is already counting down to power off. Send a power on command to cancel.")
            return
        }
        func countdownText(_ seconds: Int) -> String {
            "Projector \(index) power will turn off in \(seconds) second\(seconds == 1 ? "" : "s"). Send a power on command to cancel."
        }
        let line = log(countdownText(Self.powerOffDelaySeconds))
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            for elapsed in 1...Self.powerOffDelaySeconds {
                // Sleep until an absolute deadline so the countdown doesn't drift.
                do {
                    try await Task.sleep(until: start.advanced(by: .seconds(elapsed)), clock: clock)
                } catch {
                    return   // cancelled by power on or by closing connections
                }
                guard let self else { return }
                let remaining = Self.powerOffDelaySeconds - elapsed
                if remaining > 0 { self.updateLog(line, countdownText(remaining)) }
            }
            guard let self, !Task.isCancelled else { return }
            // From here the command is on its way and can't be cancelled; a power on just powers on again.
            if self.powerOffCountdowns[index]?.token == token { self.powerOffCountdowns[index] = nil }
            self.updateLog(line, "Projector \(index) is powering off…")
            do {
                try await connection.powerOff()
                self.updateLog(line, "Projector \(index) powered off.")
            } catch {
                self.updateLog(line, "ERROR: Projector \(index) didn't power off: \(error.localizedDescription).")
            }
        }
        powerOffCountdowns[index] = PowerOffCountdown(token: token, task: task, logLine: line)
    }

    private func cancelAllPowerOffCountdowns() {
        for (index, countdown) in powerOffCountdowns {
            countdown.task.cancel()
            updateLog(countdown.logLine, "Projector \(index) power off cancelled because connections were closed.")
        }
        powerOffCountdowns.removeAll()
    }

    // MARK: - Status replies

    /// Reads a value with `read` and replies `/projector/{index}/{command}/status <value>`.
    /// If it can't be read, replies `/projector/{index}/{command}/status "error" "<reason>"`.
    private func replyWithStatus(index: UInt,
                                 connection: ProjectorConnection?,
                                 command: String,
                                 what: String,
                                 transport: OSCServer.Transport,
                                 reply: @escaping OSCServer.Reply,
                                 read: @escaping (ProjectorConnection) async throws -> OSCArgument) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let address = "/projector/\(index)/\(command)/status"
            let response: OSCMessage
            if let connection {
                do {
                    response = OSCMessage(address: address, arguments: [try await read(connection)])
                } catch {
                    self.log("ERROR: Couldn't read the \(what) of \(connection.label): \(error.localizedDescription).")
                    response = OSCMessage(address: address, arguments: [.string("error"), .string(error.localizedDescription)])
                }
            } else {
                self.log("ERROR: An OSC \(command) status request targets projector \(index), which isn't in the projector list.")
                response = OSCMessage(address: address, arguments: [.string("error"), .string("projector \(index) isn't in the projector list")])
            }
            reply(response)
            if self.logReceivedOSC { self.log("OSC reply sent (\(transport.rawValue)): \(response)") }
        }
    }

    // MARK: - Fades

    private func startFade(_ command: FadeCommand) {
        let endIntensity = command.endIntensity
        let fadeTime = command.fadeTime ?? defaultFadeTime

        for index in command.projectorIndexes {
            guard let connection = connections[index] else {
                log("ERROR: An OSC fade targets projector index \(index), which isn't in the projector list.")
                continue
            }
            // A new command for this projector replaces any fade already running on it.
            fades[index]?.task.cancel()
            connection.discardQueuedLaserPower()

            let token = UUID()
            let task = Task { @MainActor [weak self] in
                await self?.runFade(on: connection, endIntensity: endIntensity, fadeTime: fadeTime)
                self?.fadeFinished(index: index, token: token)
            }
            fades[index] = ActiveFade(token: token, task: task)
        }
    }

    private func fadeFinished(index: UInt, token: UUID) {
        if fades[index]?.token == token { fades[index] = nil }
    }

    private func cancelAllFades() {
        for fade in fades.values { fade.task.cancel() }
        fades.removeAll()
    }

    /// Reads the current laser power, then steps it to `endIntensity` over `fadeTime` seconds.
    private func runFade(on connection: ProjectorConnection, endIntensity: Float, fadeTime: Float) async {
        guard connection.state == .connected else {
            log("ERROR: Can't fade \(connection.label) because it isn't connected.")
            return
        }

        let startIntensity: Float
        do {
            startIntensity = Float(try await connection.getNumberProperty(ProjectorConnection.laserPowerProperty))
        } catch {
            if !Task.isCancelled {
                log("ERROR: Couldn't read the laser power of \(connection.label): \(error.localizedDescription). Fade skipped.")
            }
            return
        }
        if Task.isCancelled { return }

        let fadeSteps = abs(endIntensity - startIntensity)
        let finalValue = Self.clampedPercent(endIntensity)
        var lastSent = Self.clampedPercent(startIntensity)

        if fadeSteps == 0 { return }
        if fadeTime <= 0 {   // a zero fade time is a snap
            if finalValue != lastSent { connection.setLaserPower(finalValue) }
            return
        }

        // One step per percentage point, spread evenly so the whole loop takes fadeTime seconds.
        let stepCount = max(1, Int(fadeSteps.rounded(.up)))
        let delay = Double(fadeTime) / Double(stepCount)
        let clock = ContinuousClock()
        let startTime = clock.now

        for i in 0...stepCount {
            if i > 0 {
                // Sleep until an absolute deadline so timing doesn't drift.
                do {
                    try await Task.sleep(until: startTime.advanced(by: .seconds(delay * Double(i))), clock: clock)
                } catch {
                    return   // cancelled by a newer command or by closing connections
                }
            }
            if Task.isCancelled { return }

            let value = startIntensity + (endIntensity - startIntensity) * Float(i) / Float(stepCount)
            let rounded = Self.clampedPercent(value)
            if rounded == lastSent { continue }   // unchanged since the last step: don't send

            guard connection.setLaserPower(rounded) else {
                log("ERROR: Fade on \(connection.label) stopped because the connection dropped.")
                return
            }
            lastSent = rounded
        }
    }

    private static func clampedPercent(_ value: Float) -> Int {
        min(100, max(0, Int(value.rounded())))
    }
}
