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
    static let requestTimeout: Duration = .seconds(3)
    /// How long to wait for a property.set confirmation before sending the next queued value anyway.
    static let setConfirmationTimeout: Duration = .seconds(1)
    static let reconnectDelay: Duration = .seconds(3)
    /// The Pulse API needs no delimiter between JSON messages. Change to "\n" if your firmware wants one.
    static let messageTerminator = ""

    let projector: Projector
    @Published private(set) var state: ProjectorConnectionState = .disconnected

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
        }
        // Anything else (property.set confirmations, property.changed notifications) needs no action.
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
