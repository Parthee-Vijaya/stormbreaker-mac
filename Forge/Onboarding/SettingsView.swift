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
                TextField("Foretrukken tiltale (fx P)", text: $model.preferences.preferredName)
                Text("Sådan hilser Forge på dig på startskærmen — “Hvad vil du bygge, P?”.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Udseende") {
                Picker("Tema", selection: $model.preferences.appearance) {
                    Text("Mørk · Midnat").tag("dark")
                    Text("Lys").tag("light")
                }
                .pickerStyle(.segmented)
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

            Section("Modeller & roller") {
                rolePicker("Plan-model", selection: $model.preferences.planModelID)
                rolePicker("Build-model", selection: $model.preferences.buildModelID)
                rolePicker("Dansk copy-model", selection: $model.preferences.copyModelID)
                Toggle("Kør dansk copy-pass automatisk efter build",
                       isOn: $model.preferences.autoCopyPass)
                    .disabled(model.preferences.copyModelID.isEmpty)
                Text("Tildel forskellige modeller til at planlægge, bygge og oversætte. Tom = brug den valgte standard-model. Copy-passet omskriver kun synlig tekst til dansk — koden røres ikke, og det kan rulles tilbage via checkpoints.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Cloud-model (valgfri)") {
                Picker("Udbyder", selection: $model.preferences.cloudProvider) {
                    Text("Ingen / lokal").tag("")
                    Text("Google Gemini (gratis niveau)").tag("gemini")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                    Text("OpenRouter").tag("openrouter")
                    Text("NVIDIA NIM").tag("nvidiaNIM")
                }
                if !model.preferences.cloudProvider.isEmpty {
                    Button("Hent en API-nøgle hos \(OnboardingView.providerName(model.preferences.cloudProvider)) →") {
                        SystemSetup.openURL(OnboardingView.getKeyURL(model.preferences.cloudProvider))
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
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

            Section("Adfærd") {
                Toggle("Learning mode (for begyndere)", isOn: $model.preferences.learningMode)
                Text("Viser forklarings-kort ved hvert vigtigt skridt, en ordbog over fagudtryk, og en mere nybegynder-venlig tone i AI'en. Slå til hvis du er ny til at kode.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Auto-fix runtime-fejl", isOn: $model.preferences.autoFix)
                Text("Når slået til retter Forge automatisk en fejl i den kørende app uden du beder om det. Kan altid rulles tilbage via checkpoints. ‘Fix it’-knappen er tilgængelig uanset.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Funktionel røgtest af preview", isOn: $model.preferences.functionalSmokeTest)
                Text("Når en build ellers er ren, afprøver Forge automatisk den kørende app (skriver i felter, klikker på knapper) i en skjult fane for at fange fejl der først opstår ved interaktion. Tilføjer et par sekunder ved den rene build.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Verbose metrics", isOn: $model.preferences.verboseMetrics)
                Text("Viser hastighed (tokens/sek) og tid-til-første-token i statuslinjen, og en fuld token-oversigt (tur · projekt · session) i tooltippet på token-pillen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Button("Kør onboarding igen") { model.preferences.onboarded = false }
                    .foregroundStyle(Theme.accent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .preferredColorScheme(model.colorScheme)
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

    /// A role → model picker (B25). "Standard-model" (empty tag) falls back to the
    /// header-selected model. Lists every available model incl. an optional cloud
    /// one; keeps a stale id selectable so a not-currently-served model isn't lost.
    private func rolePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Standard-model").tag("")
            ForEach(model.availableModels) { config in
                Text("\(config.displayName)  ·  \(sourceLabel(config.source))").tag(config.id)
            }
            if !selection.wrappedValue.isEmpty,
               !model.availableModels.contains(where: { $0.id == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
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
