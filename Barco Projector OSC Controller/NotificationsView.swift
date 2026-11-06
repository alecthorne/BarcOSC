import SwiftUI

/// The Projector Notifications window: each projector's power state, alarm state and
/// active notifications (notification.list, kept up to date by the notification signals).
struct NotificationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Warnings and errors the projectors report. They update live while connections are open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { refresh() }
                    .disabled(!model.connectionsOpen)
                    .help("Read the active notifications from every projector again")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if !model.connectionsOpen {
                placeholder("Open connections to see each projector's notifications.")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.projectors) { projector in
                            if let connection = model.connections[projector.index] {
                                ProjectorNotificationsSection(projector: projector, connection: connection)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 560, minHeight: 300)
        // Read the lists again whenever the window opens, in case a notification timed out
        // without a notification.dismissed signal.
        .onAppear { refresh() }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func refresh() {
        guard model.connectionsOpen else { return }
        let connections = Array(model.connections.values)
        Task { @MainActor in
            for connection in connections {
                await connection.refreshNotifications()
            }
        }
    }
}

private struct ProjectorNotificationsSection: View {
    let projector: Projector
    @ObservedObject var connection: ProjectorConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(projector.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if connection.state == .connected {
                    if let systemState = connection.systemState {
                        Text("State: \(SystemStateText.display(systemState))")
                            .foregroundStyle(systemState.lowercased() == "error" ? Color.red : Color.secondary)
                    }
                    if let alarmState = connection.alarmState {
                        HStack(spacing: 5) {
                            Circle().fill(AlarmStateStyle.color(alarmState)).frame(width: 8, height: 8)
                            Text("Alarm: \(alarmState)")
                        }
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ConnectionStatusView(connection: connection)
                }
            }
            .font(.callout)

            content
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private var content: some View {
        if connection.state != .connected {
            note("Not connected.")
        } else if let notifications = connection.notifications {
            if notifications.isEmpty {
                note("No active notifications.")
            } else {
                ForEach(notifications) { notification in
                    NotificationRow(notification: notification)
                    if notification.id != notifications.last?.id { Divider() }
                }
            }
        } else {
            note("Reading notifications…")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }
}

private struct NotificationRow: View {
    let notification: ProjectorNotification

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(notification.severity.isEmpty ? "INFO" : notification.severity)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(AlarmStateStyle.color(severity: notification.severity)))
                .frame(width: 76, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.message.isEmpty ? "(no message)" : notification.message)
                    .fixedSize(horizontal: false, vertical: true)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var details: String {
        var parts: [String] = []
        if !notification.code.isEmpty { parts.append("Code \(notification.code)") }
        if !notification.timestamp.isEmpty { parts.append(notification.timestamp) }
        return parts.isEmpty ? "No code or time given" : parts.joined(separator: " · ")
    }
}
