import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.preferences.onboarded {
                OnboardingView()
                    .transition(.opacity)
            } else if model.hasStarted {
                HSplitView {
                    ChatView()
                        .frame(minWidth: 360, idealWidth: 440, maxWidth: 680)
                    PreviewPane()
                        .frame(minWidth: 480)
                }
                .transition(.opacity)
            } else {
                EmptyStateView()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Theme.canvas)
        .preferredColorScheme(.light) // forced light — keeps the B/W design + text visible under any system appearance
        .animation(.smooth(duration: 0.35), value: model.hasStarted)
        .animation(.smooth(duration: 0.35), value: model.preferences.onboarded)
    }
}
