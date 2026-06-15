import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return Group {
            if !model.preferences.onboarded {
                OnboardingView()
                    .transition(.opacity)
            } else if model.hasStarted {
                HStack(spacing: 0) {
                    if model.showProjectSidebar {
                        ProjectsSidebar()
                            .transition(.move(edge: .leading))
                        Divider().overlay(Theme.border)
                    }
                    PersistentHSplit(minLeft: 360, maxLeft: 720, minRight: 460) {
                        ChatView()
                    } right: {
                        PreviewPane()
                    }
                }
                .transition(.opacity)
                .animation(.smooth(duration: 0.28), value: model.showProjectSidebar)
            } else {
                StartScreen()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Theme.canvas)
        .preferredColorScheme(model.colorScheme) // Midnat dark by default; light via Settings
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: model.toast)
        .animation(.smooth(duration: 0.35), value: model.hasStarted)
        .animation(.smooth(duration: 0.35), value: model.preferences.onboarded)
        .sheet(isPresented: $model.showCommandPalette) { CommandPaletteView() }
        .sheet(isPresented: $model.showShortcuts) { ShortcutsView() }
    }
}
