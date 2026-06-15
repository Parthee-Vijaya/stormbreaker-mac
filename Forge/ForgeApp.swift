import SwiftUI

@main
struct ForgeApp: App {
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
                Divider()
                Button("Stop generering") { appDelegate.model.cancelGeneration() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}
