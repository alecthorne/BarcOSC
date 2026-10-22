import SwiftUI

/// The projector list. Grows one row at a time up to 10 rows, then scrolls.
/// An empty row always follows the last projector (or the empty-list message).
struct ProjectorListView: View {
    let projectors: [Projector]
    let connections: [UInt: ProjectorConnection]
    @Binding var selection: UInt?

    static let rowHeight: CGFloat = 22
    static let maxVisibleRows = 10

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
