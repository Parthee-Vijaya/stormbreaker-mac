import SwiftUI
import AppKit

@main
struct ForgeApp: App {
    private static let repoURL = URL(string: "https://github.com/Parthee-Vijaya/forge-mac")!
    private static let newIssueURL = URL(string: "https://github.com/Parthee-Vijaya/forge-mac/issues/new/choose")!
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nyt projekt") { appDelegate.model.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Forge") {
                Button("Kommando-palette…") { appDelegate.model.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Tastaturgenveje") { appDelegate.model.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
                Divider()
                Button("Genindlæs preview") { appDelegate.model.reloadPreview() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Skift kode / preview") { appDelegate.model.toggleRightPane() }
                    .keyboardShortcut("\\", modifiers: .command)
                Button("Terminal") { if appDelegate.model.hasStarted { appDelegate.model.showTerminal = true } }
                    .keyboardShortcut("t", modifiers: .command)
                Button(appDelegate.model.remoteSharing ? "Stop iPhone-deling" : "Del til iPhone (companion)") {
                    appDelegate.model.toggleRemoteSharing()
                }
                Divider()
                Button("Stop generering") { appDelegate.model.cancelGeneration() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Rapportér en fejl…") { NSWorkspace.shared.open(Self.newIssueURL) }
                Button("Forge på GitHub") { NSWorkspace.shared.open(Self.repoURL) }
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}
