import AppKit
import SwiftUI

@main
struct BarcoProjectorOSCControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Barco Projector OSC Controller", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)   // height follows the projector list and log size
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Settings…") { model.openSettings() }
                    .keyboardShortcut("o")
                    .disabled(model.connectionsOpen)
            }
            CommandGroup(after: .saveItem) {
                Button("Save Settings…") { model.saveSettings() }
                    .keyboardShortcut("s")
            }
        }

        Window("Projector Command Log", id: "commandLog") {
            CommandLogView()
                .environmentObject(model)
        }
        .defaultSize(width: 760, height: 420)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Save defaultFadeTime and close any open projector connections.
        AppModel.shared.prepareForQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
