import SwiftUI
import AppKit
import ForgeKit

/// First-run wizard: name → location → model → cloud key → GitHub → Vercel →
/// memory → AI_RULES → done. Writes Preferences + Keychain on finish.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var step = 0
    @State private var cloudKey = ""
    @State private var discovered: [ModelConfig] = []
    @State private var discovering = false
    @State private var githubLine = "Tjekker…"
    @State private var vercelLine = "Tjekker…"

    private let lastStep = 9
    private let optionalSteps: Set<Int> = [4, 5, 6]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                content($model)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32).padding(.vertical, 28)
            }
            Divider().overlay(Theme.border)
            footer
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Theme.canvas)
        .preferredColorScheme(.light)
        .task(id: step) { await onStepAppear($model) }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 9) {
            Circle().fill(Theme.accent).frame(width: 9, height: 9)
            Text("Forge").font(Theme.wordmark(16)).foregroundStyle(Theme.ink)
            Spacer()
            Text("Trin \(min(step + 1, lastStep)) / \(lastStep)")
                .font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Tilbage") { step -= 1 }.buttonStyle(.plain).foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            if optionalSteps.contains(step) {
                Button("Spring over") { step += 1 }.buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
            }
            Button(step == lastStep ? "Byg dit første projekt" : "Næste") {
                if step == lastStep { finish() } else { step += 1 }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.accent, in: Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Steps

    @ViewBuilder
    private func content(_ model: Bindable<AppModel>) -> some View {
        switch step {
        case 0:
            stepShell("Velkommen til Forge", "Beskriv en app, og se den blive bygget — live. Lad os sætte dig op (et minut).") {
                EmptyView()
            }
        case 1:
            stepShell("Hvad skal vi kalde dig?", "Bruges i appen og fortæller agenten hvem den hjælper.") {
                textField("Dit navn", model.preferences.userName)
            }
        case 2:
            stepShell("Hvor skal dine projekter ligge?", "Standard er app-mappen. Vælg en anden hvis du vil have dem et bestemt sted.") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.wrappedValue.preferences.projectsRoot.isEmpty
                             ? "Standard (Application Support/Forge)"
                             : model.wrappedValue.preferences.projectsRoot)
                            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Vælg mappe…") { pickFolder(model) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    }
                    .padding(12).overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
                    if !model.wrappedValue.preferences.projectsRoot.isEmpty {
                        Button("Nulstil til standard") { model.wrappedValue.preferences.projectsRoot = "" }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                    }
                }
            }
        case 3:
            stepShell("Vælg din standard-model", "Fundet lokalt på din maskine. Du kan altid skifte i appen.") {
                modelList(model)
            }
        case 4:
            stepShell("Cloud-model (valgfri)", "Tilføj en nøgle for at bruge NVIDIA NIM, OpenAI eller Anthropic. Kan springes over — alt virker lokalt.") {
                cloudStep(model)
            }
        case 5:
            stepShell("GitHub", "Bruges til at pushe genererede apps. Du kan springe over og gøre det senere.") {
                VStack(alignment: .leading, spacing: 10) {
                    statusRow(githubLine)
                    textField("GitHub-bruger/org (owner)", model.preferences.githubOwner)
                }
            }
        case 6:
            stepShell("Vercel (valgfri)", "Bruges til at deploye. Spring over hvis du ikke deployer endnu.") {
                VStack(alignment: .leading, spacing: 10) {
                    statusRow(vercelLine)
                    textField("Vercel team/scope (valgfri)", model.preferences.vercelScope)
                }
            }
        case 7:
            stepShell("Global memory", "Hvad skal Forge altid huske om dig? Injiceres i hver tur (fx “TypeScript strict, minimale deps, dansk UI-tekst”).") {
                editor(model.preferences.memory, height: 150)
            }
        case 8:
            stepShell("Standard projekt-regler (AI_RULES.md)", "Hvert nyt projekt får denne fil — den styrer agenten og følger med koden ved deploy.") {
                editor(model.preferences.rulesTemplate, height: 200)
            }
        default:
            stepShell("Alt klar, \(model.wrappedValue.preferences.userName.isEmpty ? "kom i gang" : model.wrappedValue.preferences.userName)! 🎉",
                      "Du kan ændre alt senere i Indstillinger (⌘,).") {
                summary(model)
            }
        }
    }

    private func stepShell<Inner: View>(_ title: String, _ subtitle: String, @ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.inkSoft)
            }
            inner()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textField(_ placeholder: String, _ binding: Binding<String>) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.ink).tint(Theme.accent)
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
    }

    private func editor(_ binding: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: binding)
            .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink).tint(Theme.accent)
            .scrollContentBackground(.hidden).padding(8).frame(height: height)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(text.contains("Logget ind") || text.contains("som ") ? Theme.positive : Theme.inkFaint)
                .frame(width: 7, height: 7)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.inkSoft)
        }
    }

    private func modelList(_ model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if discovering {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finder modeller…").foregroundStyle(Theme.inkSoft) }
            } else if discovered.isEmpty {
                Text("Ingen lokale modeller fundet. Start Ollama eller LM Studio og prøv igen.")
                    .font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                Button("Prøv igen") { Task { await loadModels(model) } }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            } else {
                ForEach(discovered) { config in
                    Button { model.wrappedValue.preferences.defaultModelID = config.id } label: {
                        HStack(spacing: 8) {
                            Circle().fill(dotColor(config.source)).frame(width: 7, height: 7)
                            Text(config.displayName).font(.system(size: 13)).foregroundStyle(Theme.ink)
                            Text(sourceLabel(config.source)).font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                            Spacer()
                            if model.wrappedValue.preferences.defaultModelID == config.id {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(model.wrappedValue.preferences.defaultModelID == config.id ? Theme.fill : .clear,
                                    in: RoundedRectangle(cornerRadius: Theme.radiusM))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func cloudStep(_ model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Provider", selection: model.preferences.cloudProvider) {
                Text("NVIDIA NIM").tag("nvidiaNIM")
                Text("OpenAI").tag("openai")
                Text("Anthropic").tag("anthropic")
            }
            .pickerStyle(.segmented).labelsHidden()
            textField("Model-id (fx nvidia/llama-3.1-nemotron-70b-instruct)", model.preferences.cloudModel)
            SecureField("API-nøgle", text: $cloudKey)
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.ink).tint(Theme.accent)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
            Text("Nøglen gemmes sikkert i Keychain.").font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
        }
    }

    private func summary(_ model: Bindable<AppModel>) -> some View {
        let p = model.wrappedValue.preferences
        return VStack(alignment: .leading, spacing: 6) {
            summaryRow("Navn", p.userName.isEmpty ? "—" : p.userName)
            summaryRow("Placering", p.projectsRoot.isEmpty ? "Standard" : p.projectsRoot)
            summaryRow("Model", p.defaultModelID.isEmpty ? "Lokal (auto)" : p.defaultModelID)
            summaryRow("Cloud", cloudKey.isEmpty ? "Sprunget over" : "\(p.cloudProvider.isEmpty ? "nvidiaNIM" : p.cloudProvider)")
            summaryRow("GitHub", p.githubOwner.isEmpty ? "—" : p.githubOwner)
            summaryRow("Vercel", p.vercelScope.isEmpty ? "—" : p.vercelScope)
            summaryRow("Memory", p.memory.isEmpty ? "—" : "\(p.memory.prefix(40))…")
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.inkFaint).frame(width: 80, alignment: .leading)
            Text(value).font(.system(size: 12.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private func onStepAppear(_ model: Bindable<AppModel>) async {
        if step == 1, model.wrappedValue.preferences.userName.isEmpty {
            model.wrappedValue.preferences.userName = NSFullUserName()
        }
        if step == 3 { await loadModels(model) }
        if step == 5 {
            let login = await Shell.login("gh api user --jq .login 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
            githubLine = login.isEmpty ? "Ikke logget ind (kør `gh auth login` i Terminal)" : "Logget ind som \(login)"
            if model.wrappedValue.preferences.githubOwner.isEmpty, !login.isEmpty {
                model.wrappedValue.preferences.githubOwner = login
            }
        }
        if step == 6 {
            let who = await Shell.login("vercel whoami 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = who.split(separator: "\n").last.map(String.init) ?? ""
            vercelLine = line.isEmpty ? "Ikke logget ind (kør `vercel login`)" : "Logget ind som \(line)"
        }
    }

    private func loadModels(_ model: Bindable<AppModel>) async {
        discovering = true
        discovered = await ModelDiscovery.discoverLocal()
        discovering = false
        if model.wrappedValue.preferences.defaultModelID.isEmpty, !discovered.isEmpty {
            model.wrappedValue.preferences.defaultModelID = AppModel.preferredDefault(discovered).id
        }
    }

    private func pickFolder(_ model: Bindable<AppModel>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Vælg"
        if panel.runModal() == .OK, let url = panel.url {
            model.wrappedValue.preferences.projectsRoot = url.path
        }
    }

    private func finish() {
        let key = cloudKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            KeychainStore.set(key, account: KeychainStore.cloudKeyAccount)
            if model.preferences.cloudProvider.isEmpty { model.preferences.cloudProvider = "nvidiaNIM" }
        }
        model.completeOnboarding()
    }

    private func dotColor(_ source: ModelConfig.Source) -> Color {
        switch source {
        case .ollama: Theme.positive
        case .lmStudio: Color.purple
        case .cloud: Color.blue
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
