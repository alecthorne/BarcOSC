import Foundation
import Network

/// Listens for OSC over both UDP and TCP (SLIP-framed), on one port, on the loopback interface,
/// one chosen interface, or all interfaces. QLab 5 network patches can use either transport.
@MainActor
final class OSCServer {
    enum Transport: String {
        case udp = "UDP"
        case tcp = "TCP"
    }

    struct Configuration {
        enum Interface {
            case all
            case loopback
            /// The IPv4 addresses of one interface.
            case addresses([String])
        }

        var port: UInt16
        var interface: Interface
        /// Used in Log lines, e.g. "Ethernet – en0".
        var interfaceLabel: String
        /// The sender IPv4 addresses to accept, or nil to accept any sender.
        var allowedSenders: Set<String>?
        /// When false, UDP is still listened on, but only so dropped messages can be reported
        /// with `onIgnoredUDP`; nothing received over UDP is handled.
        var acceptsUDP: Bool
    }

    /// Sends an OSC message back to whoever sent the message being handled.
    typealias Reply = @MainActor (OSCMessage) -> Void

    /// Takes effect the next time `start()` is called.
    var configuration: Configuration
    var port: UInt16 { configuration.port }
    var onMessage: ((OSCMessage, Transport, @escaping Reply) -> Void)?
    var onLog: ((String) -> Void)?
    var onParseError: ((String) -> Void)?
    /// Called with the sender's address when a sender that isn't allowed is turned away.
    var onRejectedSender: ((String, Transport) -> Void)?
    /// Called with the sender's address, and the OSC address if the packet parses, for each
    /// UDP packet dropped because `acceptsUDP` is false.
    var onIgnoredUDP: ((_ sender: String, _ oscAddress: String?) -> Void)?

    /// One listener per transport, and per local address when listening on a specific interface.
    private struct ListenerKey: Hashable {
        let transport: Transport
        /// nil when not bound to one address.
        let localAddress: String?
    }

    /// A listener that fails (e.g. after a network change, or while another app holds the port)
    /// is started again after this delay, for as long as the server is running.
    static let listenerRetryDelay: Duration = .seconds(5)
    /// UDP has no "closed", so each sender's flow is forgotten after this long without a packet.
    /// Otherwise a sender that uses a new source port per message would pile up flows forever.
    static let udpIdleTimeout: Duration = .seconds(10 * 60)
    static let udpIdleCheckInterval: Duration = .seconds(30)

    private var listeners: [ListenerKey: NWListener] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var streamDecoders: [ObjectIdentifier: OSCStreamDecoder] = [:]
    private var udpLastActivity: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    private var retryTasks: [ListenerKey: Task<Void, Never>] = [:]
    /// Listeners whose failure has been logged; cleared when they're working again.
    private var failedListeners: Set<ListenerKey> = []
    private var idleCheckTask: Task<Void, Never>?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func start() {
        stop()
        let localAddresses: [String?]
        if case .addresses(let addresses) = configuration.interface {
            localAddresses = addresses
        } else {
            localAddresses = [nil]
        }
        for address in localAddresses {
            startListener(ListenerKey(transport: .udp, localAddress: address))
            startListener(ListenerKey(transport: .tcp, localAddress: address))
        }
        idleCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: OSCServer.udpIdleCheckInterval)
                self?.closeIdleUDPFlows()
            }
        }
    }

    func stop() {
        idleCheckTask?.cancel()
        idleCheckTask = nil
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        failedListeners.removeAll()
        for listener in listeners.values {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listeners.removeAll()
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        streamDecoders.removeAll()
        udpLastActivity.removeAll()
    }

    // MARK: - Listeners

    private func startListener(_ key: ListenerKey) {
        let transport = key.transport
        let parameters: NWParameters
        switch transport {
        case .udp: parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        case .tcp:
            // Keepalive closes connections from senders that vanish without closing
            // (cable pulled, machine crashed), instead of keeping them forever.
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        if case .loopback = configuration.interface {
            parameters.requiredInterfaceType = .loopback   // only accept OSC from this Mac
        }
        parameters.allowLocalEndpointReuse = true

        let location = description(of: key)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let listener: NWListener
        do {
            if let address = key.localAddress {
                guard let ipv4 = IPv4Address(address) else {
                    // Never fall back to listening on every interface.
                    onLog?("ERROR: Couldn't listen for OSC on \(location) (\(transport.rawValue)) because \"\(address)\" isn't a valid IPv4 address.")
                    return
                }
                // Bind to the interface's address so only OSC arriving for it is received.
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ipv4), port: nwPort)
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: nwPort)
            }
        } catch {
            listenerFailed(key, "ERROR: Couldn't listen for OSC on \(location) (\(transport.rawValue)): \(error.localizedDescription).")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerStateChanged(state, key: key) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, transport: transport) }
        }
        listeners[key] = listener
        listener.start(queue: .main)
    }

    /// e.g. "Ethernet – en0 (10.10.3.11) port 9090" or "all interfaces port 9090".
    private func description(of key: ListenerKey) -> String {
        let address = key.localAddress.map { " (\($0))" } ?? ""
        return "\(configuration.interfaceLabel)\(address) port \(port)"
    }

    private func listenerStateChanged(_ state: NWListener.State, key: ListenerKey) {
        let transport = key.transport.rawValue
        // In TCP only mode the UDP listener exists only to report dropped messages.
        let reportOnly = key.transport == .udp && !configuration.acceptsUDP
        let note = reportOnly ? " It's only used to note UDP messages that TCP only mode ignores; TCP isn't affected." : ""
        switch state {
        case .ready:
            let recovered = failedListeners.remove(key) != nil ? "Recovered: " : ""
            onLog?(recovered + (reportOnly
                   ? "Watching \(description(of: key)) (UDP) to note UDP messages, which are ignored because OSC Input is set to TCP only."
                   : "Listening for OSC on \(description(of: key)) (\(transport))."))
        case .waiting(let error):
            onLog?("ERROR: OSC \(transport) listener on \(description(of: key)) is waiting: \(error.localizedDescription)\(note)")
        case .failed(let error):
            listenerFailed(key, "ERROR: OSC \(transport) listener on \(description(of: key)) failed: \(error.localizedDescription). Is another app already using port \(port)?\(note)")
        default:
            break
        }
    }

    /// Discards a failed listener and starts it again after `listenerRetryDelay`.
    /// The failure is logged once; the Log notes "Recovered" when it's listening again.
    private func listenerFailed(_ key: ListenerKey, _ message: String) {
        if let listener = listeners.removeValue(forKey: key) {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        if failedListeners.insert(key).inserted {
            onLog?("\(message) Retrying every \(Self.listenerRetryDelay.components.seconds) seconds.")
        }
        retryTasks[key]?.cancel()
        retryTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: OSCServer.listenerRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[key] = nil
            self.startListener(key)
        }
    }

    /// Forgets UDP flows that have been silent for `udpIdleTimeout`.
    private func closeIdleUDPFlows() {
        let now = ContinuousClock.now
        for (key, lastActivity) in udpLastActivity where now - lastActivity >= Self.udpIdleTimeout {
            if let connection = connections[key] {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            forget(key)
        }
    }

    // MARK: - Incoming connections

    private func accept(_ connection: NWConnection, transport: Transport) {
        if let allowed = configuration.allowedSenders {
            let sender = Self.ipv4Address(of: connection.endpoint)
            guard let sender, allowed.contains(sender) else {
                connection.cancel()
                onRejectedSender?(sender ?? "\(connection.endpoint)", transport)
                return
            }
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        switch transport {
        case .tcp: streamDecoders[key] = OSCStreamDecoder()
        case .udp: udpLastActivity[key] = .now
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed:   // e.g. keepalive found the sender gone
                    connection?.cancel()
                    self?.forget(key)
                case .cancelled:
                    self?.forget(key)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, transport: transport)
    }

    /// The sender's IPv4 address in dotted-quad form, including IPv4 senders seen as IPv4-mapped IPv6.
    private static func ipv4Address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        let address: IPv4Address?
        switch host {
        case .ipv4(let ipv4): address = ipv4
        case .ipv6(let ipv6): address = ipv6.asIPv4
        case .name(let name, _): return ProjectorValidator.normalizedIPv4(name)
        @unknown default: address = nil
        }
        return address.map { $0.rawValue.map(String.init).joined(separator: ".") }
    }

    private func forget(_ key: ObjectIdentifier) {
        connections[key] = nil
        streamDecoders[key] = nil
        udpLastActivity[key] = nil
    }

    private func receive(on connection: NWConnection, transport: Transport) {
        let key = ObjectIdentifier(connection)
        switch transport {
        case .udp:
            // Each UDP datagram is one OSC packet.
            connection.receiveMessage { [weak self] data, _, _, error in
                MainActor.assumeIsolated {
                    guard let self, self.connections[key] != nil else { return }
                    if let data, !data.isEmpty {
                        self.udpLastActivity[key] = .now
                        if self.configuration.acceptsUDP {
                            self.handlePacket(data, from: connection, transport: .udp)
                        } else {
                            let sender = Self.ipv4Address(of: connection.endpoint) ?? "\(connection.endpoint)"
                            self.onIgnoredUDP?(sender, (try? OSCParser.parse(data))?.first?.address)
                        }
                    }
                    if error == nil {
                        self.receive(on: connection, transport: .udp)
                    } else {
                        connection.cancel()
                        self.forget(key)
                    }
                }
            }
        case .tcp:
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                MainActor.assumeIsolated {
                    guard let self, self.connections[key] != nil else { return }
                    if let data, !data.isEmpty {
                        var decoder = self.streamDecoders[key] ?? OSCStreamDecoder()
                        let packets: [Data]
                        do {
                            packets = try decoder.feed(data)
                        } catch {
                            self.onParseError?("Closed a TCP connection from \(connection.endpoint) because \(error).")
                            connection.cancel()
                            self.forget(key)
                            return
                        }
                        self.streamDecoders[key] = decoder
                        for packet in packets { self.handlePacket(packet, from: connection, transport: .tcp) }
                    }
                    if isComplete || error != nil {
                        connection.cancel()
                        self.forget(key)
                    } else {
                        self.receive(on: connection, transport: .tcp)
                    }
                }
            }
        }
    }

    private func handlePacket(_ data: Data, from connection: NWConnection, transport: Transport) {
        let key = ObjectIdentifier(connection)
        let reply: Reply = { [weak self, weak connection] message in
            // Replies can arrive after the sender has gone away; drop them then.
            guard let self, let connection, self.connections[key] != nil else { return }
            self.send(message, on: connection, transport: transport)
        }
        do {
            for message in try OSCParser.parse(data) {
                onMessage?(message, transport, reply)
            }
        } catch {
            onParseError?("Received \(data.count) bytes over \(transport.rawValue) that aren't a valid OSC message (\(error)).")
        }
    }

    // MARK: - Sending replies

    private func send(_ message: OSCMessage, on connection: NWConnection, transport: Transport) {
        let packet = OSCEncoder.encode(message)
        let content: Data
        switch transport {
        case .udp: content = packet
        case .tcp: content = (streamDecoders[ObjectIdentifier(connection)] ?? OSCStreamDecoder()).encode(packet)
        }
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.onLog?("ERROR: Couldn't send OSC reply \"\(message)\" over \(transport.rawValue): \(error.localizedDescription)")
            }
        })
    }
}
