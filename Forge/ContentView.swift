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
                VStack(spacing: 0) {
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
                    Divider().overlay(Theme.border)
                    StatusBar()
                }
                // C5: the working split slides in from the right (preview-from-trailing
                // choreography) when the first build starts, instead of a flat crossfade.
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
                .animation(.smooth(duration: 0.28), value: model.showProjectSidebar)
            } else {
                StartScreen()
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .leading).combined(with: .opacity)))
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
        .sheet(isPresented: $model.showTerminal) { TerminalView() }
    }
}

/// A persistent VS Code-style status bar at the bottom of the working view:
/// dev-server state + port, git branch, current file (in code view) on the left;
/// deploy state, active model, and the project token total on the right.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            serverSegment
            if let branch = model.gitBranch {
                segment(icon: "arrow.triangle.branch", text: branch)
            }
            if model.rightPaneMode == .code, let file = model.selectedFile {
                segment(icon: "doc", text: (file as NSString).lastPathComponent)
            }
            Spacer(minLength: 8)
            deploySegment
            HStack(spacing: 5) {
                Circle().fill(ModelPicker.dotColor(model.selectedModel.source)).frame(width: 6, height: 6)
                Text(model.selectedModel.displayName)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
            }
            .foregroundStyle(Theme.inkSoft)
            .help("Aktiv model")
            if model.projectTokens > 0 {
                segment(icon: "number", text: AppModel.formatTokens(model.projectTokens))
                    .help(model.tokenTooltip)
            }
            if model.preferences.verboseMetrics, let line = model.lastMetricsLine {
                segment(icon: "speedometer", text: line)
                    .help(model.tokenTooltip)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Divider().overlay(Theme.border) }
    }

    private var serverSegment: some View {
        let state = serverState
        return HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 6, height: 6)
            Text(state.label)
        }
        .foregroundStyle(Theme.inkSoft)
        .help("Dev-server status")
    }

    private var serverState: (color: Color, label: String) {
        switch model.serverPhase {
        case .idle, .stopped: return (Theme.inkFaint, "dev-server stoppet")
        case .installingDependencies: return (Theme.warning, "installerer…")
        case .startingServer: return (Theme.warning, "starter…")
        case .running:
            let port = model.previewURL?.port.map { ":\($0)" } ?? ""
            return (Theme.positive, "kører \(port)")
        case .failed: return (Color(nsColor: .systemRed), "dev-server fejl")
        }
    }

    @ViewBuilder private var deploySegment: some View {
        if model.isDeploying {
            segment(icon: "arrow.up.circle", text: "deployer…")
        } else if let live = model.deployLiveURL {
            Button { NSWorkspace.shared.open(live) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.positive)
                    Text("live").foregroundStyle(Theme.inkSoft)
                }
            }
            .buttonStyle(.plain)
            .help(live.absoluteString)
        }
    }

    private func segment(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(Theme.inkFaint)
            Text(text).foregroundStyle(Theme.inkSoft)
        }
    }
}
