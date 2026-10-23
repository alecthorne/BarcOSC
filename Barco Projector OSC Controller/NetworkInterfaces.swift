import Foundation
import SystemConfiguration

/// A network interface OSC can be received on, e.g. Ethernet – en0 (10.10.3.11).
struct NetworkInterfaceInfo: Identifiable, Equatable {
    /// BSD name, e.g. "en0".
    let name: String
    /// The name System Settings shows, e.g. "Wi-Fi" or "USB 10/100/1000 LAN".
    let displayName: String
    let ipv4Addresses: [String]

    var id: String { name }

    /// e.g. `Ethernet – en0`
    var label: String { "\(displayName) – \(name)" }

    /// e.g. `Ethernet – en0 (10.10.3.11)`
    var menuLabel: String { "\(label) (\(ipv4Addresses.joined(separator: ", ")))" }
}

/// Keeps a live list of this Mac's network interfaces that are up and have an IPv4 address,
/// other than loopback. Reads the interface table directly rather than using NWPathMonitor,
/// which leaves out interfaces it doesn't consider routable, such as an isolated show network.
@MainActor
final class NetworkInterfaceMonitor {
    static let refreshInterval: Duration = .seconds(2)

    /// Called with the full list whenever it changes, and once when started.
    var onChange: (([NetworkInterfaceInfo]) -> Void)?

    private var interfaces: [NetworkInterfaceInfo]?
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func refresh() {
        let addresses = Self.ipv4AddressesByInterface()
        let displayNames = Self.displayNamesByInterface()
        let current = addresses.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                NetworkInterfaceInfo(name: name,
                                     displayName: displayNames[name] ?? "Network Interface",
                                     ipv4Addresses: addresses[name] ?? [])
            }
        guard current != interfaces else { return }
        interfaces = current
        onChange?(current)
    }

    /// The names macOS shows in System Settings, keyed by BSD name.
    private static func displayNamesByInterface() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in all {
            if let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
               let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsdName] = displayName
            }
        }
        return names
    }

    /// The IPv4 addresses of each interface that is up, other than loopback, keyed by BSD name.
    private static func ipv4AddressesByInterface() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: [String]] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result[String(cString: entry.pointee.ifa_name), default: []].append(String(cString: host))
        }
        return result
    }
}
