import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var selectedIndex: UInt?
    @State private var showingAddSheet = false
    @State private var editingProjector: Projector?
    @State private var confirmingDelete = false
    @State private var fadeTimeText = ""
    @State private var fadeTimeTextAtFocus = ""
    @FocusState private var fadeTimeFocused: Bool
    @FocusState private var addButtonFocused: Bool
    @State private var logHeight: CGFloat = LogTextView.height(forLines: 10)

    private var selectedProjector: Projector? {
        model.projectors.first { $0.index == selectedIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projectors").font(.headline)

            ProjectorListView(projectors: model.projectors,
                              connections: model.connections,
                              selection: $selectedIndex)

            HStack {
                Button("Add Projector...") { showingAddSheet = true }
                    .disabled(model.connectionsOpen)
                    .focused($addButtonFocused)
                Button("Edit Projector...") { editingProjector = selectedProjector }
                    .disabled(model.connectionsOpen || selectedProjector == nil)
                Button("Delete Projector") { confirmingDelete = true }
                    .disabled(model.connectionsOpen || selectedProjector == nil)
                Spacer()
                Button("Open Connections") { model.openConnections() }
                    .disabled(model.connectionsOpen || model.projectors.isEmpty)
                Button("Close Connections") { model.closeConnections() }
                    .disabled(!model.connectionsOpen)
            }
            .alert("Are you sure?", isPresented: $confirmingDelete, presenting: selectedProjector) { projector in
                Button("Yes, Delete", role: .destructive) {
                    model.deleteProjector(index: projector.index)
                    selectedIndex = nil
                }
                Button("No, Keep", role: .cancel) { }
            } message: { projector in
                Text("This removes \(projector.displayName) from the list.")
            }

            if model.connectionsOpen {
                Text("Connections are open and the app is listening for OSC on 127.0.0.1:\(String(AppModel.oscPort)). Close connections to add, edit, or delete projectors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("Default Fade Time:")
                TextField("Default Fade Time", text: $fadeTimeText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .focused($fadeTimeFocused)
                    .onSubmit { commitFadeTime() }
                Text("seconds").foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Toggle("Log Received OSC Messages", isOn: $model.logReceivedOSC)
                Toggle("Log Sent Projector Commands", isOn: $model.logProjectorCommands)
            }
            .toggleStyle(.checkbox)

            LogPanel(title: "Log",
                     text: model.logText,
                     height: $logHeight,
                     onClear: { model.clearLog() },
                     onSave: { model.saveLog(model.logText, suggestedName: "Barco Projector Log") })
        }
        .padding()
        .defaultFocus($addButtonFocused, true)   // "Add Projector..." has focus when the window opens
        .background {
            // Clicking empty window space ends editing, which commits the fade time.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { fadeTimeFocused = false }
        }
        .frame(minWidth: 640, maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)   // window height follows the list and log
        .onAppear {
            fadeTimeText = model.defaultFadeTimeText
            fadeTimeTextAtFocus = fadeTimeText
        }
        .onChange(of: fadeTimeFocused) { focused in
            if focused {
                fadeTimeTextAtFocus = fadeTimeText
            } else if fadeTimeText != fadeTimeTextAtFocus {
                commitFadeTime()
            }
        }
        .onChange(of: model.defaultFadeTime) { _ in
            // e.g. a settings file was opened
            fadeTimeText = model.defaultFadeTimeText
            fadeTimeTextAtFocus = fadeTimeText
        }
        .onChange(of: model.logProjectorCommands) { enabled in
            if enabled { openWindow(id: "commandLog") }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddProjectorView().environmentObject(model)
        }
        .sheet(item: $editingProjector) { projector in
            AddProjectorView(editing: projector, onSaved: { selectedIndex = $0 })
                .environmentObject(model)
        }
        .alert(model.alert?.title ?? "Error",
               isPresented: Binding(get: { model.alert != nil },
                                    set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.alert?.message ?? "")
        }
    }

    /// Validates the field. On failure the model alerts and logs, and the field reverts to defaultFadeTime.
    private func commitFadeTime() {
        model.commitDefaultFadeTime(from: fadeTimeText)
        fadeTimeText = model.defaultFadeTimeText
        fadeTimeTextAtFocus = fadeTimeText
    }
}
