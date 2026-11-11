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
    @FocusState private var openButtonFocused: Bool
    @State private var oscPortText = ""
    @State private var oscPortTextAtFocus = ""
    @FocusState private var oscPortFocused: Bool
    @State private var oscSendersText = ""
    @State private var oscSendersTextAtFocus = ""
    @FocusState private var oscSendersFocused: Bool
    @State private var logHeight: CGFloat = LogTextView.height(forLines: 10)
    /// Shown while connections are closed, so OSC Input can be changed; collapsed when they open.
    @State private var settingsExpanded = true
    /// Stays however it was last left, across launches.
    @AppStorage("logExpanded") private var logExpanded = true

    private var textFieldFocused: Bool {
        fadeTimeFocused || oscPortFocused || oscSendersFocused
    }

    private var selectedProjector: Projector? {
        model.projectors.first { $0.index == selectedIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projectors").font(.sectionTitle)

            ProjectorListView(projectors: model.projectors,
                              connections: model.connections,
                              showsStatus: model.connectionsOpen,
                              selection: $selectedIndex)

            HStack {
                Button("Add Projector...") { showingAddSheet = true }
                    .disabled(model.connectionsOpen)
                Button("Edit Projector...") { editingProjector = selectedProjector }
                    .disabled(model.connectionsOpen || selectedProjector == nil)
                Button("Delete Projector") { confirmingDelete = true }
                    .disabled(model.connectionsOpen || selectedProjector == nil)
                Spacer()
                Button("Notifications...") { openWindow(id: "notifications") }
                    .help("Show each projector's power state, alarm state and active notifications")
                Button("Open Connections") {
                    // Clicking a button doesn't end editing, so apply a port or address still being typed.
                    if commitOSCPortIfChanged() && commitOSCSendersIfChanged() { model.openConnections() }
                }
                    // Return opens connections, except while typing in a field, where Return
                    // just applies the field.
                    .keyboardShortcut(textFieldFocused ? nil : .defaultAction)
                    .focused($openButtonFocused)
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
                Text("Connections are open and the app is listening for OSC on \(model.oscListenDescription). Close connections to add, edit, or delete projectors or to change OSC Input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                CollapsibleSectionHeader(title: "Settings", isExpanded: $settingsExpanded)
                ProportionalColumns(spacing: 16) {
                    oscInputSection
                    Color(nsColor: .separatorColor)
                        .frame(width: 1)
                        .layoutValue(key: ProportionalColumns.FixedWidth.self, value: true)
                    fadesSection
                }
                // Lines up with the "Settings" title, past the chevron, to read as its subsections.
                .padding(.leading, CollapsibleSectionHeader.titleIndent)
                .padding(.top, 8)
                // Collapsed, it stays in the layout with no height, so the window keeps the
                // minimum width it needs.
                .frame(height: settingsExpanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(settingsExpanded ? 1 : 0)
                .disabled(!settingsExpanded)
                .accessibilityHidden(!settingsExpanded)
            }

            Divider()

            LogPanel(title: "Log",
                     text: model.logText,
                     isExpanded: $logExpanded,
                     height: $logHeight,
                     onClear: { model.clearLog() },
                     onSave: { model.saveLog(model.logText, suggestedName: "Barco Projector Log") }) {
                HStack(spacing: 20) {
                    Toggle("Log Received OSC Messages", isOn: $model.logReceivedOSC)
                    Toggle("Log Sent Projector Commands", isOn: $model.logProjectorCommands)
                }
                .toggleStyle(.checkbox)
            }
        }
        // No minWidth frame: a frame reports its minWidth as its minimum, hiding the wider
        // minimum the Settings row needs. That row sets the window's minimum width.
        .padding()
        // "Open Connections" has focus when the window opens (when Full Keyboard Access lets buttons take focus).
        .defaultFocus($openButtonFocused, true)
        .background {
            // Clicking empty window space ends editing, which commits the fade time.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    fadeTimeFocused = false
                    oscPortFocused = false
                    oscSendersFocused = false
                }
        }
        .narrowestAtContentMinimumWidth()
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)   // window height follows the list and log
        .onAppear {
            fadeTimeText = model.defaultFadeTimeText
            fadeTimeTextAtFocus = fadeTimeText
            resetOSCFields()
            // Otherwise macOS puts the cursor in the first text field, and Return wouldn't
            // reach "Open Connections". Wait a turn, until the window has picked a first responder.
            DispatchQueue.main.async {
                fadeTimeFocused = false
                oscPortFocused = false
                oscSendersFocused = false
            }
        }
        .onChange(of: oscPortFocused) { focused in
            if focused { oscPortTextAtFocus = oscPortText } else { commitOSCPortIfChanged() }
        }
        .onChange(of: oscSendersFocused) { focused in
            if focused { oscSendersTextAtFocus = oscSendersText } else { commitOSCSendersIfChanged() }
        }
        .onChange(of: model.oscInput) { _ in
            // e.g. a settings file was opened
            resetOSCFields()
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
        .onChange(of: model.connectionsOpen) { open in
            settingsExpanded = !open
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

    // MARK: - Fades

    // Its own section: unlike OSC Input, it stays editable while connections are open.
    private var fadesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fades").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    Text("Default Fade Time:")
                    HStack(spacing: 6) {
                        TextField("Default Fade Time", text: $fadeTimeText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .focused($fadeTimeFocused)
                            .onSubmit { commitFadeTime() }
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            }
            // Each line stays whole; the window can't get narrower than the longer one.
            Text("Used when a fade command doesn't include a time, e.g. /projector/1/fade up.\n/projector/1/fade up 2 fades over 2 seconds instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - OSC Input

    private var oscInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OSC Input").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Listen on interface:").gridColumnAlignment(.trailing)
                    Picker("Listen on interface", selection: Binding(get: { model.oscInput.interface },
                                                                     set: { model.setOSCInterface($0) })) {
                        Text("All interfaces").tag(OSCInputSettings.allInterfaces)
                        Text("This Mac only (Loopback)").tag(OSCInputSettings.loopbackInterface)
                        Divider()
                        ForEach(model.networkInterfaces) { interface in
                            Text(interface.menuLabel).tag(interface.name)
                        }
                        // Keep a saved interface that isn't plugged in, so the setting isn't lost.
                        if !model.oscInput.isLoopback, !model.oscInput.isAllInterfaces,
                           model.selectedNetworkInterface == nil {
                            Text("\(model.oscInput.interface) (not connected)").tag(model.oscInput.interface)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                GridRow {
                    Text("Listen on port:")
                    TextField("Listen on port", text: $oscPortText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($oscPortFocused)
                        .onSubmit { commitOSCPort() }
                }

                GridRow {
                    Text("Accept OSC over:")
                    Picker("Accept OSC over", selection: Binding(get: { model.oscInput.tcpOnly },
                                                                 set: { model.setOSCTCPOnly($0) })) {
                        Text("TCP only").tag(true)
                        Text("UDP and TCP").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .fixedSize()
                }

                GridRow {
                    Text("Accept OSC from:")
                    if model.oscInput.isLoopback {
                        // Always one line: it fits even at the window's minimum width, and without
                        // fixedSize the Grid can give it only the width of the column's widest control.
                        Text("This Mac only - OSC Input is listening on the Loopback interface.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Aligning on the last baseline puts the field beside "Only from:".
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Picker("Accept OSC from", selection: Binding(get: { model.oscInput.onlyFromAllowedSenders },
                                                                         set: { model.setOSCOnlyFromAllowedSenders($0) })) {
                                Text("Any address").tag(false)
                                Text("Only from:").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            .fixedSize()

                            TextField("10.10.3.20, 10.10.3.21", text: $oscSendersText)
                                .labelsHidden()
                                .frame(width: 260)
                                .focused($oscSendersFocused)
                                .onSubmit { commitOSCSenders() }
                                .disabled(!model.oscInput.onlyFromAllowedSenders)
                        }
                    }
                }

                // In the value column, so it lines up with the controls above.
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(model.oscSendToDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .disabled(model.connectionsOpen)
    }

    private func resetOSCFields() {
        oscPortText = model.oscPortText
        oscPortTextAtFocus = oscPortText
        oscSendersText = model.oscInput.allowedSendersText
        oscSendersTextAtFocus = oscSendersText
    }

    /// Validates the port field. On failure the model alerts and logs, and the field reverts.
    @discardableResult
    private func commitOSCPort() -> Bool {
        let accepted = model.commitOSCPort(from: oscPortText)
        oscPortText = model.oscPortText
        oscPortTextAtFocus = oscPortText
        return accepted
    }

    /// Validates the "Only from" field. On failure the model alerts and logs, and the field reverts.
    @discardableResult
    private func commitOSCSenders() -> Bool {
        let accepted = model.commitOSCAllowedSenders(from: oscSendersText)
        oscSendersText = model.oscInput.allowedSendersText
        oscSendersTextAtFocus = oscSendersText
        return accepted
    }

    /// Commits the port field if it was edited. Returns false if the edit was invalid.
    @discardableResult
    private func commitOSCPortIfChanged() -> Bool {
        oscPortText == model.oscPortText ? true : commitOSCPort()
    }

    /// Commits the "Only from" field if it was edited. Returns false if the edit was invalid.
    @discardableResult
    private func commitOSCSendersIfChanged() -> Bool {
        oscSendersText == model.oscInput.allowedSendersText ? true : commitOSCSenders()
    }
}

/// A section title with a disclosure chevron; clicking either shows or hides the section.
struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    private static let chevronWidth: CGFloat = 14
    private static let chevronSpacing: CGFloat = 4
    /// How far the title sits from the header's leading edge.
    static let titleIndent = chevronWidth + chevronSpacing

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: Self.chevronSpacing) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.chevronWidth)
                Text(title).font(.sectionTitle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide \(title)" : "Show \(title)")
    }
}

extension Font {
    /// The Projectors, Settings and Log headings, a step above the .headline subsection titles.
    static let sectionTitle = Font.title3.weight(.semibold)
}

/// Side-by-side columns, top-aligned. At their narrowest each column has its ideal width; any
/// extra width is shared among them in proportion to those widths. Subviews marked FixedWidth
/// (e.g. a separator) keep their width and get the row's full height.
struct ProportionalColumns: Layout {
    var spacing: CGFloat

    struct FixedWidth: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(for: proposal.width, subviews: subviews)
        let height = rowHeight(widths: widths, subviews: subviews)
        return CGSize(width: widths.reduce(0, +) + totalSpacing(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(for: bounds.width, subviews: subviews)
        let height = rowHeight(widths: widths, subviews: subviews)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            let fixed = subview[FixedWidth.self]
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: fixed ? height : nil))
            x += width + spacing
        }
    }

    private func totalSpacing(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }

    /// Ideal widths, plus a proportional share of whatever width is offered beyond them.
    private func columnWidths(for offeredWidth: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let flexibleTotal = zip(subviews, ideals).filter { !$0.0[FixedWidth.self] }.map(\.1).reduce(0, +)
        let extra = (offeredWidth ?? 0) - ideals.reduce(0, +) - totalSpacing(subviews)
        guard extra > 0, extra.isFinite, flexibleTotal > 0 else { return ideals }
        return zip(subviews, ideals).map { subview, ideal in
            subview[FixedWidth.self] ? ideal : ideal + extra * ideal / flexibleTotal
        }
    }

    private func rowHeight(widths: [CGFloat], subviews: Subviews) -> CGFloat {
        zip(subviews, widths)
            .filter { !$0.0[FixedWidth.self] }
            .map { $0.0.sizeThatFits(ProposedViewSize(width: $0.1, height: nil)).height }
            .max() ?? 0
    }
}

/// Never lays its content out narrower than the content's own minimum width, so when the
/// window asks for its minimum size, text isn't measured as wrapping at a width it can't reach.
/// Unlike .frame(minWidth:), it doesn't hide that minimum width.
struct ContentMinimumWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: width(for: proposal.width, content: content),
                                                     height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func width(for proposedWidth: CGFloat?, content: LayoutSubview) -> CGFloat? {
        let minimum = content.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        guard let proposedWidth, proposedWidth.isFinite else { return proposedWidth }
        return max(proposedWidth, minimum)
    }
}

extension View {
    func narrowestAtContentMinimumWidth() -> some View {
        ContentMinimumWidth { self }
    }
}
