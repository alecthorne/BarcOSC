import Foundation
import Network
import Combine

enum ProjectorConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case retrying(String)
}

enum ProjectorRequestError: LocalizedError {
    case notConnected
    case timedOut
    case connectionClosed
    case rpcError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "the projector is not connected"
        case .timedOut: return "the projector did not reply in time"
        case .connectionClosed: return "the connection closed before the projector replied"
        case .rpcError(let message): return "the projector returned an error: \(message)"
        case .invalidResponse(let text): return "the projector sent an unexpected reply: \(text)"
        }
    }
}

/// One active notification (warning, error and so on) the projector reports through
/// notification.list and the notification.emitted signal.
struct ProjectorNotification: Identifiable, Equatable {
    let id: String
    /// "INFO", "CAUTION", "WARNING", "ERROR" or "CRITICAL".
    let severity: String
    let code: String
    let message: String
    let timestamp: String

    init?(_ value: Any?) {
        guard let dict = value as? [String: Any] else { return nil }
        func text(_ key: String) -> String {
            if let string = dict[key] as? String { return string }
            if let other = dict[key], !(other is NSNull) { return "\(other)" }
            return ""
        }
        let id = text("id")
        guard !id.isEmpty else { return nil }
        self.id = id
        severity = text("severity").uppercased()
        code = text("code")
        message = text("message")
        timestamp = text("timestamp")
    }

    /// Higher is more severe. Unknown severities rank with INFO.
    var severityRank: Int {
        ["INFO": 0, "CAUTION": 1, "WARNING": 2, "ERROR": 3, "CRITICAL": 4][severity] ?? 0
    }
}

/// A kept-alive JSON-RPC (Barco Pulse API) connection to one projector on TCP port 9090.
/// Reconnects automatically until `close()` is called.
@MainActor
final class ProjectorConnection: ObservableObject {
    static let port: UInt16 = 9090
    static let laserPowerProperty = "illumination.sources.laser.power"
    /// Writable shutter state: "Open" or "Closed".
    static let shutterTargetProperty = "optics.shutter.target"
    /// Read-only shutter state as the projector reports it, e.g. "Open" or "Closed".
    static let shutterPositionProperty = "optics.shutter.position"
    /// Read-only power state, e.g. "on", "standby", "conditioning", "deconditioning", "ready", "eco".
    static let systemStateProperty = "system.state"
    /// Read-only overall health: "Ok", "Warning", "Alert", "Error" or "Fatal".
    static let alarmStateProperty = "environment.alarmstate"
    /// Properties the connection subscribes to so the projector list can show them live.
    static let statusProperties = [shutterPositionProperty, laserPowerProperty, systemStateProperty, alarmStateProperty]
    static let notificationEmittedSignal = "notification.emitted"
    static let notificationDismissedSignal = "notification.dismissed"
    static let requestTimeout: Duration = .seconds(3)
    /// How long to wait for a property.set confirmation before sending the next queued value anyway.
    static let setConfirmationTimeout: Duration = .seconds(1)
    static let reconnectDelay: Duration = .seconds(3)
    /// The Pulse API needs no delimiter between JSON messages. Change to "\n" if your firmware wants one.
    static let messageTerminator = ""

    let projector: Projector
    @Published private(set) var state: ProjectorConnectionState = .disconnected
    /// The shutter position the projector last reported ("Open" or "Closed"), or nil if not known yet.
    @Published private(set) var shutterPosition: String?
    /// The laser power in percent the projector last reported, or nil if not known yet.
    @Published private(set) var laserPower: Double?
    /// The power state the projector last reported, e.g. "on" or "standby", or nil if not known yet.
    @Published private(set) var systemState: String?
    /// The alarm state the projector last reported ("Ok", "Warning", "Alert", "Error" or "Fatal"),
    /// or nil if not known yet.
    @Published private(set) var alarmState: String?
    /// The projector's active notifications, most severe first, or nil until they've been read.
    @Published private(set) var notifications: [ProjectorNotification]?

    /// Errors and connection events for the main Log.
    var onLog: ((String) -> Void)?
    /// Every JSON message sent or received, for the command log window.
    var onTraffic: ((String) -> Void)?

    private var connection: NWConnection?
    private var shouldStayOpen = false
    private var reconnectTask: Task<Void, Never>?
    private var lastProblem: String?
    private var receiveBuffer: [UInt8] = []
    private var nextRequestID = 1
    /// A successful reply's result. The reply's raw JSON text is kept for error messages.
    private struct RequestReply {
        let result: Any?
        let text: String
    }
    private var pendingRequests: [Int: CheckedContinuation<RequestReply, Error>] = [:]

    // Laser power set pacing (see setLaserPower)
    private var powerSetInFlightID: Int?
    private var queuedPower: Int?

    init(projector: Projector) {
        self.projector = projector
    }

    var label: String { projector.displayName }
    private var shortLabel: String { "[P\(projector.index) \(projector.ipAddress)]" }

    // MARK: - Open / close

    func open() {
        shouldStayOpen = true
        connect()
    }

    func close() {
        shouldStayOpen = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        state = .disconnected
    }

    private func connect() {
        guard shouldStayOpen else { return }
        reconnectTask = nil

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)

        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let newConnection = NWConnection(host: NWEndpoint.Host(projector.ipAddress), port: port, using: parameters)
        connection = newConnection
        receiveBuffer.removeAll()
        state = .connecting

        let key = ObjectIdentifier(newConnection)
        newConnection.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated { self?.connectionStateChanged(newState, key: key) }
        }
        newConnection.start(queue: .main)
        receive(on: newConnection)
    }

    private func connectionStateChanged(_ newState: NWConnection.State, key: ObjectIdentifier) {
        guard let connection, ObjectIdentifier(connection) == key else { return }   // stale connection
        switch newState {
        case .ready:
            state = .connected
            onLog?(lastProblem == nil ? "Connected to \(label)." : "Reconnected to \(label).")
            lastProblem = nil
            startStatusUpdates(key: key)
        case .waiting(let error):
            connectionLost("can't reach the projector (\(error.localizedDescription)).")
        case .failed(let error):
            connectionLost("the connection failed (\(error.localizedDescription)).")
        default:
            break
        }
    }

    /// Tears down the current connection and, while connections should stay open, retries.
    private func connectionLost(_ problem: String) {
        if problem != lastProblem {
            onLog?("ERROR: \(label): \(problem) Retrying every \(Self.reconnectDelay.components.seconds) seconds.")
            lastProblem = problem
        }
        teardown()
        guard shouldStayOpen else { state = .disconnected; return }
        state = .retrying(problem)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ProjectorConnection.reconnectDelay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func teardown() {
        if let connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
        receiveBuffer.removeAll()
        powerSetInFlightID = nil
        queuedPower = nil
        shutterPosition = nil
        laserPower = nil
        systemState = nil
        alarmState = nil
        notifications = nil
        let waiting = pendingRequests
        pendingRequests.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: ProjectorRequestError.connectionClosed)
        }
    }

    // MARK: - Receiving

    private func receive(on receivingConnection: NWConnection) {
        receivingConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let current = self.connection, current === receivingConnection else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(contentsOf: data)
                    self.processReceiveBuffer()
                }
                if isComplete {
                    self.connectionLost("the projector closed the connection.")
                } else if let error {
                    self.connectionLost("receive error (\(error.localizedDescription)).")
                } else {
                    self.receive(on: receivingConnection)
                }
            }
        }
    }

    private func processReceiveBuffer() {
        while let object = Self.extractJSONObject(from: &receiveBuffer) {
            handleIncoming(object)
        }
        if receiveBuffer.count > 1_000_000 {   // never-ending garbage; start over
            onLog?("ERROR: \(label) sent more than 1 MB without a complete JSON message. Discarding it.")
            receiveBuffer.removeAll()
        }
    }

    /// Removes and returns the first complete top-level JSON object in `buffer`, if there is one.
    /// The Pulse API sends JSON objects back to back without a delimiter, so we track brace depth.
    static func extractJSONObject(from buffer: inout [UInt8]) -> [UInt8]? {
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var depth = 0
        var inString = false
        var escaped = false
        var start: Int?

        for i in buffer.indices {
            let byte = buffer[i]
            guard let objectStart = start else {
                if byte == openBrace { start = i; depth = 1 }
                continue   // skip whitespace between objects
            }
            if inString {
                if escaped { escaped = false }
                else if byte == backslash { escaped = true }
                else if byte == quote { inString = false }
                continue
            }
            switch byte {
            case quote:
                inString = true
            case openBrace:
                depth += 1
            case closeBrace:
                depth -= 1
                if depth == 0 {
                    let object = Array(buffer[objectStart...i])
                    buffer.removeSubrange(0...i)
                    return object
                }
            default:
                break
            }
        }

        if let start, start > 0 {
            buffer.removeSubrange(0..<start)
        } else if start == nil {
            buffer.removeAll()
        }
        return nil
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
        onTraffic?("← \(shortLabel) \(text)")

        guard let object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else {
            onLog?("ERROR: \(label) sent a reply that isn't valid JSON: \(text)")
            return
        }
        let id = (object["id"] as? NSNumber)?.intValue

        if let id, id == powerSetInFlightID {   // a laser power set was confirmed (or rejected)
            powerSetInFlightID = nil
            flushQueuedPower()
        }

        if let error = object["error"] {
            let message = Self.describeRPCError(error)
            if let id, let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(throwing: ProjectorRequestError.rpcError(message))
            } else {
                onLog?("ERROR: \(label) returned an error: \(message)")
            }
            return
        }

        if let id, let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: RequestReply(result: object["result"], text: text))
            return
        }

        switch object["method"] as? String {
        case "property.changed":
            handlePropertyChanged(object["params"])
        case "signal.callback":
            handleSignalCallback(object["params"])
        default:
            break   // Anything else (property.set confirmations) needs no action.
        }
    }

    // MARK: - Live status

    /// Subscribes to the status properties and notification signals, then reads the current values
    /// and active notifications, since a subscription only reports later changes.
    private func startStatusUpdates(key: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // One at a time, so a property this firmware doesn't have can't stop the others updating.
            for property in Self.statusProperties {
                guard self.isCurrentConnection(key) else { return }
                do {
                    _ = try await self.request(method: "property.subscribe", params: ["property": property])
                } catch {
                    guard self.isCurrentConnection(key) else { return }
                    self.onLog?("ERROR: Couldn't subscribe to \(property) updates from \(self.label): \(error.localizedDescription)")
                }
            }
            guard self.isCurrentConnection(key) else { return }
            do {
                _ = try await self.request(method: "signal.subscribe",
                                           params: ["signal": [Self.notificationEmittedSignal, Self.notificationDismissedSignal]])
            } catch {
                guard self.isCurrentConnection(key) else { return }
                self.onLog?("ERROR: Couldn't subscribe to notifications from \(self.label): \(error.localizedDescription)")
            }
            for property in Self.statusProperties {
                guard self.isCurrentConnection(key) else { return }
                do {
                    let reply = try await self.getProperty(property)
                    guard self.isCurrentConnection(key) else { return }
                    self.applyStatus(property: property, value: reply.result)
                } catch {
                    guard self.isCurrentConnection(key) else { return }
                    self.onLog?("ERROR: Couldn't read \(property) from \(self.label): \(error.localizedDescription)")
                }
            }
            guard self.isCurrentConnection(key) else { return }
            await self.refreshNotifications(logNew: true)
        }
    }

    /// Reads the projector's active notifications with notification.list and replaces the stored list.
    /// With logNew, notifications of WARNING or above that weren't already known go to the main Log.
    func refreshNotifications(logNew: Bool = false) async {
        guard state == .connected, let connection else { return }
        let key = ObjectIdentifier(connection)
        do {
            let reply = try await request(method: "notification.list")
            guard isCurrentConnection(key) else { return }
            // The result is the array itself; accept {"notifications": [...]} too.
            guard let items = (reply.result as? [Any])
                    ?? ((reply.result as? [String: Any])?["notifications"] as? [Any]) else {
                throw ProjectorRequestError.invalidResponse(reply.text)
            }
            let known = Set((notifications ?? []).map(\.id))
            let list = items.compactMap { ProjectorNotification($0) }
            if logNew {
                for notification in list where !known.contains(notification.id) { logNotification(notification) }
            }
            notifications = Self.sorted(list)
        } catch {
            guard isCurrentConnection(key) else { return }
            onLog?("ERROR: Couldn't read notifications from \(label): \(error.localizedDescription)")
        }
    }

    private static func sorted(_ list: [ProjectorNotification]) -> [ProjectorNotification] {
        list.sorted {
            $0.severityRank != $1.severityRank ? $0.severityRank > $1.severityRank : $0.timestamp > $1.timestamp
        }
    }

    private func logNotification(_ notification: ProjectorNotification) {
        guard notification.severityRank >= 2 else { return }   // WARNING and above
        let code = notification.code.isEmpty ? "" : " (code \(notification.code))"
        onLog?("\(notification.severity): \(label) reports: \(notification.message)\(code)")
    }

    /// params.signal is an array of single-entry {signalname: arguments} objects.
    private func handleSignalCallback(_ params: Any?) {
        guard let params = params as? [String: Any] else { return }
        let entries: [[String: Any]]
        if let list = params["signal"] as? [[String: Any]] {
            entries = list
        } else if let single = params["signal"] as? [String: Any] {
            entries = [single]
        } else {
            return
        }
        for entry in entries {
            for (signal, value) in entry {
                let arguments = value as? [String: Any] ?? [:]
                switch signal {
                case Self.notificationEmittedSignal:
                    // The argument is {"notification": {...}}; accept the bare notification too.
                    guard let notification = ProjectorNotification(arguments["notification"])
                            ?? ProjectorNotification(arguments) else { continue }
                    var list = notifications ?? []
                    let isNew = !list.contains { $0.id == notification.id }
                    list.removeAll { $0.id == notification.id }
                    list.append(notification)
                    notifications = Self.sorted(list)
                    if isNew { logNotification(notification) }
                case Self.notificationDismissedSignal:
                    guard let id = arguments["id"].map({ $0 as? String ?? "\($0)" }) else { continue }
                    notifications?.removeAll { $0.id == id }
                default:
                    break
                }
            }
        }
    }

    private func isCurrentConnection(_ key: ObjectIdentifier) -> Bool {
        guard let connection, state == .connected else { return false }
        return ObjectIdentifier(connection) == key
    }

    /// params.property is an array of single-entry {property: value} objects.
    private func handlePropertyChanged(_ params: Any?) {
        guard let params = params as? [String: Any] else { return }
        let entries: [[String: Any]]
        if let list = params["property"] as? [[String: Any]] {
            entries = list
        } else if let single = params["property"] as? [String: Any] {
            entries = [single]
        } else {
            return
        }
        for entry in entries {
            for (property, value) in entry {
                applyStatus(property: property, value: value)
            }
        }
    }

    private func applyStatus(property: String, value: Any?) {
        switch property {
        case Self.shutterPositionProperty:
            shutterPosition = value as? String
        case Self.laserPowerProperty:
            laserPower = (value as? NSNumber)?.doubleValue
        case Self.systemStateProperty:
            systemState = value as? String
        case Self.alarmStateProperty:
            let reported = value as? String
            let previous = alarmState
            alarmState = reported
            guard let newState = reported, newState.caseInsensitiveCompare(previous ?? "") != .orderedSame else { return }
            if newState.caseInsensitiveCompare("Ok") == .orderedSame {
                // Only worth a line when it's recovering, not on the first read.
                if previous != nil { onLog?("\(label) alarm state is back to Ok.") }
            } else {
                onLog?("\(newState.uppercased()): \(label) alarm state is \(newState). Click Notifications... for details.")
            }
        default:
            break
        }
    }

    private static func describeRPCError(_ error: Any) -> String {
        if let dict = error as? [String: Any] {
            let message = dict["message"] as? String ?? "unknown error"
            if let code = dict["code"] { return "\(message) (code \(code))" }
            return message
        }
        return "\(error)"
    }

    // MARK: - Sending

    /// Sends one JSON-RPC request and returns its id, or nil if not connected.
    @discardableResult
    private func send(method: String, params: [String: Any]? = nil) -> Int? {
        guard state == .connected, let connection else { return nil }
        let id = nextRequestID
        nextRequestID += 1
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { payload["params"] = params }
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            onLog?("ERROR: Couldn't encode a \(method) request for \(label).")
            return nil
        }
        onTraffic?("→ \(shortLabel) \(String(decoding: json, as: UTF8.self))")
        var bytes = json
        bytes.append(contentsOf: Array(Self.messageTerminator.utf8))
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onLog?("ERROR: Couldn't send \(method) to \(self.label): \(error.localizedDescription)")
            }
        })
        return id
    }

    /// property.get for a numeric property.
    func getNumberProperty(_ property: String) async throws -> Double {
        let value = try await getProperty(property)
        guard let number = value.result as? NSNumber else { throw ProjectorRequestError.invalidResponse(value.text) }
        return number.doubleValue
    }

    /// property.get for a string (or enum) property.
    func getStringProperty(_ property: String) async throws -> String {
        let value = try await getProperty(property)
        guard let string = value.result as? String else { throw ProjectorRequestError.invalidResponse(value.text) }
        return string
    }

    private func getProperty(_ property: String) async throws -> RequestReply {
        try await request(method: "property.get", params: ["property": property])
    }

    /// Powers the projector on. A rejection from the projector is logged when it arrives.
    /// Returns false if the projector isn't connected.
    @discardableResult
    func powerOn() -> Bool {
        send(method: "system.poweron") != nil
    }

    /// Powers the projector off and waits for it to accept the command (it replies with a null result).
    func powerOff() async throws {
        _ = try await request(method: "system.poweroff")
    }

    /// Sends a request and waits for its reply. Throws if the projector returns an error,
    /// doesn't reply in time, or the connection closes first.
    private func request(method: String, params: [String: Any]? = nil) async throws -> RequestReply {
        guard state == .connected else { throw ProjectorRequestError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            guard let id = send(method: method, params: params) else {
                continuation.resume(throwing: ProjectorRequestError.notConnected)
                return
            }
            pendingRequests[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: ProjectorConnection.requestTimeout)
                self?.pendingRequests.removeValue(forKey: id)?.resume(throwing: ProjectorRequestError.timedOut)
            }
        }
    }

    /// Opens or closes the shutter. A rejection from the projector is logged when it arrives.
    /// Returns false if the projector isn't connected.
    @discardableResult
    func setShutter(open: Bool) -> Bool {
        guard state == .connected else { return false }
        return send(method: "property.set",
                    params: ["property": Self.shutterTargetProperty, "value": open ? "Open" : "Closed"]) != nil
    }

    /// Sets the laser power. Barco recommends waiting for each property.set confirmation before
    /// setting the same property again, so while a set is unconfirmed only the newest value is held
    /// and sent as soon as the confirmation (or a 1 s timeout) arrives. A fade therefore always ends
    /// on its final value even if the projector can't keep up with every step.
    /// Returns false if the projector isn't connected.
    @discardableResult
    func setLaserPower(_ value: Int) -> Bool {
        guard state == .connected else { return false }
        if powerSetInFlightID != nil {
            queuedPower = value
        } else {
            sendPowerSet(value)
        }
        return true
    }

    /// Drops a value still waiting from an earlier fade, so it can't land after a new fade starts.
    func discardQueuedLaserPower() {
        queuedPower = nil
    }

    private func sendPowerSet(_ value: Int) {
        queuedPower = nil
        guard let id = send(method: "property.set",
                            params: ["property": Self.laserPowerProperty, "value": value]) else { return }
        powerSetInFlightID = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ProjectorConnection.setConfirmationTimeout)
            guard let self, self.powerSetInFlightID == id else { return }
            self.powerSetInFlightID = nil
            self.flushQueuedPower()
        }
    }

    private func flushQueuedPower() {
        guard powerSetInFlightID == nil, let value = queuedPower else { return }
        sendPowerSet(value)
    }
}
