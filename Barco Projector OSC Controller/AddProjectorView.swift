import SwiftUI

/// Adds a new projector, or edits `editing` when one is given.
struct AddProjectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var editing: Projector?
    /// Called with the projector's (possibly changed) index after a successful save.
    var onSaved: (UInt) -> Void = { _ in }

    @State private var indexText = ""
    @State private var name = ""
    @State private var ipText = ""
    @State private var errorMessage: String?

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Projector" : "Add Projector").font(.headline)

            Form {
                TextField("Projector Number:", text: $indexText, prompt: Text("OSC message target number"))
                TextField("Name:", text: $name, prompt: Text("e.g. FOH SL or BARCO-1"))
                TextField("IP Address:", text: $ipText, prompt: Text("e.g. 10.10.3.5"))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let editing {
                indexText = String(editing.index)
                name = editing.name
                ipText = editing.ipAddress
            } else if let highest = model.projectors.map(\.index).max(), highest < UInt.max {
                // Suggest the next free index number.
                indexText = String(highest + 1)
            } else if model.projectors.isEmpty {
                indexText = "1"
            }
        }
        .alert(isEditing ? "Can't Save Projector" : "Can't Add Projector",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let error: String?
        if let editing {
            error = model.updateProjector(originalIndex: editing.index, indexText: indexText, name: name, ipText: ipText)
        } else {
            error = model.addProjector(indexText: indexText, name: name, ipText: ipText)
        }
        if let error {
            errorMessage = error
        } else {
            if let index = ProjectorValidator.parseIndex(indexText) { onSaved(index) }
            dismiss()
        }
    }
}
