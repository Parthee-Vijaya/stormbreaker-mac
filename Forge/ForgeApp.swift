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

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}
