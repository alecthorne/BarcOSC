import SwiftUI

/// The projector list. Grows one row at a time up to 10 rows, then scrolls.
/// An empty row always follows the last projector (or the empty-list message).
struct ProjectorListView: View {
    let projectors: [Projector]
    let connections: [UInt: ProjectorConnection]
    /// Shows the State, Alarm, Shutter and Laser columns. True while connections are open.
    var showsStatus: Bool = false
    @Binding var selection: UInt?

    static let rowHeight: CGFloat = 22
    static let maxVisibleRows = 10
    static let stateColumnWidth: CGFloat = 105
    static let alarmColumnWidth: CGFloat = 80
    static let shutterColumnWidth: CGFloat = 70
    static let laserColumnWidth: CGFloat = 50

    /// Projector rows (or the empty-list message) plus the trailing empty row.
    private var contentRows: Int {
        max(projectors.count, 1) + 1
    }

    private var visibleRows: Int {
        min(contentRows, Self.maxVisibleRows)
    }

    private var isScrollable: Bool {
        contentRows > Self.maxVisibleRows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if projectors.isEmpty {
                        Text("No projectors yet. Click Add Projector... to add one.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: Self.rowHeight)
                    } else {
                        ForEach(Array(projectors.enumerated()), id: \.element.id) { offset, projector in
                            row(for: projector, stripe: !offset.isMultiple(of: 2))
                        }
                    }
                    Color.clear.frame(height: Self.rowHeight)
                }
            }
            .frame(height: Self.rowHeight * CGFloat(visibleRows))
            .scrollDisabled(!isScrollable)
            .scrollIndicators(isScrollable ? .visible : .hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Number").frame(width: 60, alignment: .leading)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("IP Address").frame(width: 120, alignment: .leading)
            Text("Connection").frame(width: 120, alignment: .leading)
            if showsStatus {
                Text("State").frame(width: Self.stateColumnWidth, alignment: .leading)
                Text("Alarm").frame(width: Self.alarmColumnWidth, alignment: .leading)
                Text("Shutter").frame(width: Self.shutterColumnWidth, alignment: .leading)
                Text("Laser").frame(width: Self.laserColumnWidth, alignment: .trailing)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
    }

    private func row(for projector: Projector, stripe: Bool) -> some View {
        let isSelected = selection == projector.index
        return HStack(spacing: 8) {
            Text(String(projector.index))
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
            Text(projector.name.isEmpty ? "—" : projector.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(projector.ipAddress)
                .monospacedDigit()
                .frame(width: 120, alignment: .leading)
            ConnectionStatusView(connection: connections[projector.index])
                .frame(width: 120, alignment: .leading)
            if showsStatus {
                ProjectorStatusColumns(connection: connections[projector.index])
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.25)
                               : (stripe ? Color.primary.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = isSelected ? nil : projector.index }
    }
}

struct ConnectionStatusView: View {
    let connection: ProjectorConnection?

    var body: some View {
        // @ObservedObject can't be optional, so observe a live connection in its own view.
        if let connection {
            ObservedConnectionStatusView(connection: connection)
        } else {
            ConnectionStatusLabel(state: nil)
        }
    }
}

private struct ObservedConnectionStatusView: View {
    @ObservedObject var connection: ProjectorConnection

    var body: some View {
        ConnectionStatusLabel(state: connection.state)
    }
}

private struct ConnectionStatusLabel: View {
    let state: ProjectorConnectionState?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).lineLimit(1)
        }
        .help(detail)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .retrying: return .red
        case .disconnected, .none: return .gray
        }
    }

    private var text: String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .retrying: return "Retrying…"
        case .disconnected, .none: return "Closed"
        }
    }

    private var detail: String {
        if case .retrying(let problem) = state { return "Last problem: \(problem)" }
        return text
    }
}

/// The live State, Alarm, Shutter and Laser cells for one row.
private struct ProjectorStatusColumns: View {
    let connection: ProjectorConnection?

    var body: some View {
        // @ObservedObject can't be optional, so observe a live connection in its own view.
        if let connection {
            ObservedProjectorStatusColumns(connection: connection)
        } else {
            ProjectorStatusCells(systemState: nil, alarmState: nil, notificationCount: nil,
                                 shutter: nil, laserPower: nil)
        }
    }
}

private struct ObservedProjectorStatusColumns: View {
    @ObservedObject var connection: ProjectorConnection

    var body: some View {
        ProjectorStatusCells(systemState: connection.systemState,
                             alarmState: connection.alarmState,
                             notificationCount: connection.notifications?.count,
                             shutter: connection.shutterPosition,
                             laserPower: connection.laserPower)
    }
}

private struct ProjectorStatusCells: View {
    let systemState: String?
    let alarmState: String?
    let notificationCount: Int?
    let shutter: String?
    let laserPower: Double?

    var body: some View {
        Group {
            if let systemState {
                Text(SystemStateText.display(systemState))
                    .lineLimit(1)
                    .foregroundStyle(systemState.lowercased() == "error" ? Color.red : Color.primary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(width: ProjectorListView.stateColumnWidth, alignment: .leading)
        .help(systemState.map { "Power state: \(SystemStateText.display($0))" } ?? "Power state not known yet")

        HStack(spacing: 5) {
            if let alarmState {
                Circle().fill(AlarmStateStyle.color(alarmState)).frame(width: 8, height: 8)
                Text(alarmState).lineLimit(1)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(width: ProjectorListView.alarmColumnWidth, alignment: .leading)
        .help(alarmHelp)

        HStack(spacing: 5) {
            if let shutter {
                Image(systemName: shutter == "Open" ? "circle" : "circle.slash")
                    .foregroundStyle(shutter == "Open" ? Color.green : Color.secondary)
                    .imageScale(.small)
                Text(shutter).lineLimit(1)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(width: ProjectorListView.shutterColumnWidth, alignment: .leading)
        .help(shutter.map { "Shutter \($0.lowercased())" } ?? "Shutter position not known yet")

        Text(laserText)
            .monospacedDigit()
            .foregroundStyle(laserPower == nil ? .secondary : .primary)
            .frame(width: ProjectorListView.laserColumnWidth, alignment: .trailing)
            .help(laserPower == nil ? "Laser power not known yet" : "Laser power \(laserText)")
    }

    private var alarmHelp: String {
        guard let alarmState else { return "Alarm state not known yet" }
        var text = "Alarm state: \(alarmState)"
        if let notificationCount {
            text += notificationCount == 1 ? ". 1 active notification" : ". \(notificationCount) active notifications"
        }
        return text + ". Click Notifications... for details."
    }

    private var laserText: String {
        guard let laserPower else { return "—" }
        let rounded = (laserPower * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))%" : String(format: "%.1f%%", rounded)
    }
}

/// system.state values as words, e.g. "deconditioning" -> "Deconditioning".
enum SystemStateText {
    static func display(_ state: String) -> String {
        state.prefix(1).uppercased() + state.dropFirst()
    }
}

/// Colors for environment.alarmstate and notification severities.
enum AlarmStateStyle {
    static func color(_ alarmState: String) -> Color {
        switch alarmState.lowercased() {
        case "ok": return .green
        case "warning": return .yellow
        case "alert": return .orange
        case "error", "fatal": return .red
        default: return .gray
        }
    }

    static func color(severity: String) -> Color {
        switch severity.uppercased() {
        case "CAUTION": return .yellow
        case "WARNING": return .orange
        case "ERROR", "CRITICAL": return .red
        default: return .blue   // INFO
        }
    }
}
