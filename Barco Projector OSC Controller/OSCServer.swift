import Foundation
import Network

/// Listens for OSC on the loopback interface, over both UDP and TCP (SLIP-framed), on one port.
/// QLab 5 network patches can use either transport.
@MainActor
final class OSCServer {
    enum Transport: String {
        case udp = "UDP"
        case tcp = "TCP"
    }

    /// Sends an OSC message back to whoever sent the message being handled.
    typealias Reply = @MainActor (OSCMessage) -> Void

    let port: UInt16
    var onMessage: ((OSCMessage, Transport, @escaping Reply) -> Void)?
    var onLog: ((String) -> Void)?
    var onParseError: ((String) -> Void)?

    private var listeners: [Transport: NWListener] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var slipDecoders: [ObjectIdentifier: SLIPDecoder] = [:]

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        stop()
        startListener(.udp)
        startListener(.tcp)
    }

    func stop() {
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
        slipDecoders.removeAll()
    }

    // MARK: - Listeners

    private func startListener(_ transport: Transport) {
        let parameters: NWParameters
        switch transport {
        case .udp: parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        case .tcp: parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        parameters.requiredInterfaceType = .loopback   // only accept OSC from this Mac
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            onLog?("ERROR: Couldn't listen for OSC on loopback port \(port) (\(transport.rawValue)): \(error.localizedDescription)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerStateChanged(state, transport: transport) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, transport: transport) }
        }
        listeners[transport] = listener
        listener.start(queue: .main)
    }

    private func listenerStateChanged(_ state: NWListener.State, transport: Transport) {
        switch state {
        case .ready:
            onLog?("Listening for OSC on 127.0.0.1:\(port) (\(transport.rawValue)).")
        case .waiting(let error):
            onLog?("ERROR: OSC \(transport.rawValue) listener on port \(port) is waiting: \(error.localizedDescription)")
        case .failed(let error):
            onLog?("ERROR: OSC \(transport.rawValue) listener on port \(port) failed: \(error.localizedDescription). Is another app already using port \(port)?")
            listeners[transport]?.cancel()
            listeners[transport] = nil
        default:
            break
        }
    }

    // MARK: - Incoming connections

    private func accept(_ connection: NWConnection, transport: Transport) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        if transport == .tcp { slipDecoders[key] = SLIPDecoder() }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.forget(key)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, transport: transport)
    }

    private func forget(_ key: ObjectIdentifier) {
        connections[key] = nil
        slipDecoders[key] = nil
    }

    private func receive(on connection: NWConnection, transport: Transport) {
        let key = ObjectIdentifier(connection)
        switch transport {
        case .udp:
            // Each UDP datagram is one OSC packet.
            connection.receiveMessage { [weak self] data, _, _, error in
                MainActor.assumeIsolated {
                    guard let self, self.connections[key] != nil else { return }
                    if let data, !data.isEmpty { self.handlePacket(data, from: connection, transport: .udp) }
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
                        var decoder = self.slipDecoders[key] ?? SLIPDecoder()
                        let frames = decoder.feed(data)
                        self.slipDecoders[key] = decoder
                        for frame in frames { self.handlePacket(frame, from: connection, transport: .tcp) }
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
        let content = transport == .tcp ? SLIPEncoder.encode(packet) : packet
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.onLog?("ERROR: Couldn't send OSC reply \"\(message)\" over \(transport.rawValue): \(error.localizedDescription)")
            }
        })
    }
}
