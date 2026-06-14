import SwiftUI
import AppKit
import ForgeKit

/// Settings window (⌘,) — edits the same Preferences the onboarding wizard set.
/// Simple fields autosave on change; location/model/cloud changes additionally
/// re-apply runtime state (reload projects, refresh model list).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var discovered: [ModelConfig] = []
    @State private var discovering = false
    @State private var cloudKey = ""
    @State private var cloudKeyStored = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Dig") {
                TextField("Navn", text: $model.preferences.userName)
            }

            Section("Projekter") {
                HStack {
                    Text(model.preferences.projectsRoot.isEmpty
                         ? "Standard (Application Support/Forge)"
                         : model.preferences.projectsRoot)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Vælg…") { pickFolder() }
                    if !model.preferences.projectsRoot.isEmpty {
                        Button("Nulstil") {
                            model.preferences.projectsRoot = ""
                            model.applyPreferences()
                        }
                    }
                }
            }

            Section("Standard-model") {
                if discovering {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finder modeller…") }
                } else {
                    Picker("Model", selection: Binding(
                        get: { model.preferences.defaultModelID },
                        set: { newID in
                            model.preferences.defaultModelID = newID
                            model.selectedModelID = newID
                            model.savePreferences()
                        })) {
                        ForEach(discovered) { config in
                            Text("\(config.displayName)  ·  \(sourceLabel(config.source))").tag(config.id)
                        }
                        if !discovered.contains(where: { $0.id == model.preferences.defaultModelID }),
                           !model.preferences.defaultModelID.isEmpty {
                            Text(model.preferences.defaultModelID).tag(model.preferences.defaultModelID)
                        }
                    }
                    Button("Opdatér liste") { Task { await loadModels() } }
                }
            }

            Section("Cloud-model (valgfri)") {
                Picker("Udbyder", selection: $model.preferences.cloudProvider) {
                    Text("Ingen / lokal").tag("")
                    Text("NVIDIA NIM").tag("nvidiaNIM")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }
                TextField("Model-id", text: $model.preferences.cloudModel)
                    .font(.system(size: 12, design: .monospaced))
                SecureField(cloudKeyStored ? "•••••••• (gemt — indtast for at ændre)" : "API-nøgle", text: $cloudKey)
                HStack {
                    Button("Gem nøgle") {
                        let key = cloudKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        KeychainStore.set(key, account: KeychainStore.cloudKeyAccount)
                        cloudKey = ""
                        cloudKeyStored = true
                        if model.preferences.cloudProvider.isEmpty { model.preferences.cloudProvider = "nvidiaNIM" }
                        model.savePreferences()
                        Task { await model.refreshModels() }
                    }
                    .disabled(cloudKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if cloudKeyStored {
                        Button("Fjern nøgle", role: .destructive) {
                            KeychainStore.delete(account: KeychainStore.cloudKeyAccount)
                            cloudKeyStored = false
                            Task { await model.refreshModels() }
                        }
                    }
                }
                Text("Nøglen gemmes i Keychain — aldrig i klartekst.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Integrationer") {
                TextField("GitHub-bruger/org (owner)", text: $model.preferences.githubOwner)
                TextField("Vercel team/scope (valgfri)", text: $model.preferences.vercelScope)
            }

            Section("Global memory") {
                TextEditor(text: $model.preferences.memory)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
            }

            Section("Standard projekt-regler (AI_RULES.md)") {
                TextEditor(text: $model.preferences.rulesTemplate)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
            }

            Section {
                Button("Kør onboarding igen") { model.preferences.onboarded = false }
                    .foregroundStyle(Theme.accent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .preferredColorScheme(.light)
        .onChange(of: model.preferences) { _, _ in model.savePreferences() }
        .task {
            cloudKeyStored = (KeychainStore.get(account: KeychainStore.cloudKeyAccount)?.isEmpty == false)
            await loadModels()
        }
    }

    private func loadModels() async {
        discovering = true
        discovered = await ModelDiscovery.discoverLocal()
        discovering = false
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Vælg"
        if panel.runModal() == .OK, let url = panel.url {
            model.preferences.projectsRoot = url.path
            model.applyPreferences()
        }
    }

    private func sourceLabel(_ source: ModelConfig.Source) -> String {
        switch source {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .cloud: "Cloud"
        }
    }
}
