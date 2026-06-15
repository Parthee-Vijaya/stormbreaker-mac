import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ForgeKit

/// The prompt input — used both on the empty-state hero and in the chat panel.
/// Enter sends, Shift+Enter inserts a newline. Text is explicitly inked so it's
/// always visible.
struct Composer: View {
    @Binding var text: String
    var placeholder: String
    var isBusy: Bool
    var autofocus: Bool = false
    var mode: Binding<AgentLoop.Mode>? = nil
    var images: [String] = []                       // B4: attached image data URLs
    var onAttach: (() -> Void)? = nil               // paperclip → file picker
    var onRemoveImage: ((Int) -> Void)? = nil
    var onDropImages: (([URL]) -> Void)? = nil       // Finder drag-and-drop
    var onAttachLink: (() -> Void)? = nil            // link → screenshot a page to copy
    var isCapturing: Bool = false                    // a page is being screenshotted
    var isEnhancing: Bool = false                    // B14: expanding the prompt
    var onEnhance: (() -> Void)? = nil               // ✨ → expand prompt into a brief
    var onSubmit: () -> Void
    var onStop: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var dropTargeted = false

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && !isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mode { ModeToggle(mode: mode) }
            if !images.isEmpty { thumbnailStrip }
            inputRow
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusL))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusL)
                .strokeBorder(dropTargeted ? Theme.accent : (focused ? Theme.borderStrong : Theme.border),
                              lineWidth: dropTargeted ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .onAppear { if autofocus { focused = true } }
        .onDrop(of: [.fileURL], isTargeted: onDropImages == nil ? nil : $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, dataURL in
                    ZStack(alignment: .topTrailing) {
                        if let image = Self.nsImage(fromDataURL: dataURL) {
                            Image(nsImage: image)
                                .resizable().scaledToFill()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                        }
                        Button { onRemoveImage?(index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.horizontal, 2).padding(.top, 2)
        }
        .frame(height: 62)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let onDropImages else { return false }
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collected.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !collected.isEmpty { onDropImages(collected) } }
        return true
    }

    static func nsImage(fromDataURL string: String) -> NSImage? {
        guard let comma = string.firstIndex(of: ","),
              let data = Data(base64Encoded: String(string[string.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let onAttach {
                Button(action: onAttach) {
                    Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.inkSoft)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Vedhæft et billede / mockup")
                .accessibilityLabel("Vedhæft billede")
                .disabled(isBusy)
            }
            if let onAttachLink {
                Button(action: onAttachLink) {
                    Group {
                        if isCapturing {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Image(systemName: "link").font(.system(size: 14, weight: .medium))
                        }
                    }
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Kopiér design fra et link — Forge tager et skærmbillede af siden")
                .accessibilityLabel("Kopiér design fra link")
                .disabled(isBusy || isCapturing)
            }
            if let onEnhance {
                Button(action: onEnhance) {
                    Group {
                        if isEnhancing {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Image(systemName: "wand.and.stars").font(.system(size: 14, weight: .medium))
                        }
                    }
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Forbedr prompt — udvid til en detaljeret spec")
                .accessibilityLabel("Forbedr prompt")
                .disabled(isBusy || isEnhancing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .tint(Theme.accent)
                .lineLimit(1...8)
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if canSend { onSubmit() }
                    return .handled
                }

            if isBusy, let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop generation")
                .accessibilityLabel("Stop generering")
            } else {
                Button(action: onSubmit) {
                    Group {
                        if isBusy {
                            ProgressView().controlSize(.small).tint(Theme.onAccent)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(canSend || isBusy ? Theme.accent : Theme.borderStrong, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
    }
}

/// Dialog for "copy this design from a link": paste a URL → Forge screenshots
/// the page offscreen and attaches it as a visual reference. Shared by the start
/// screen and the chat composer.
struct LinkDialogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kopiér design fra et link")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Indsæt en URL. Forge tager et skærmbillede af siden og bruger det som visuel reference, så den kan genskabe designet — layout, sektioner, farver og typografi.")
                    .font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("https://stripe.com", text: $model.linkURL)
                .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.ink).tint(Theme.accent)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
                .onSubmit { model.captureDesignFromLink() }
            HStack {
                Button("Annuller") { dismiss() }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                Spacer()
                Button { model.captureDesignFromLink() } label: {
                    Text("Hent design").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preferredColorScheme(model.colorScheme)
    }
}

/// A transient confirmation shown as a floating pill (created via
/// `AppModel.showToast`). Gives visible feedback for async successes that would
/// otherwise change state silently — deploy live, Danish copy done, etc.
struct ToastMessage: Identifiable, Equatable {
    enum Style { case success, info, warning }
    let id = UUID()
    var text: String
    var icon: String
    var style: Style
}

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.icon)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text(toast.text)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 5)
    }

    private var tint: Color {
        switch toast.style {
        case .success: Theme.positive
        case .info: Theme.accent
        case .warning: Theme.warning
        }
    }
}

/// A lightweight Markdown block renderer for assistant chat messages: fenced
/// code blocks become monospace cards, list items get bullets/numbers, headings
/// are bold, and paragraphs use SwiftUI's inline markdown (bold/italic/`code`).
/// Good enough for the model's typical output without a full Markdown engine.
struct MarkdownView: View {
    let text: String

    enum Block: Equatable {
        case paragraph(String), code(String), bullet([String]), ordered([String]), heading(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(from: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS).strokeBorder(Theme.border, lineWidth: 1))
                case .bullet(let items):
                    listView(items) { _ in "•" }
                case .ordered(let items):
                    listView(items) { "\($0 + 1)." }
                case .heading(let h):
                    Text(inline(h)).font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                case .paragraph(let p):
                    Text(inline(p)).font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func listView(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(marker(i)).font(.system(size: 13.5)).foregroundStyle(Theme.inkFaint).monospacedDigit()
                    Text(inline(item)).font(.system(size: 13.5)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {                                   // fenced code
                flush(); i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if t.hasPrefix("#") {                                     // heading
                flush()
                blocks.append(.heading(String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") {               // bullet list
                flush()
                var items: [String] = []
                while i < lines.count {
                    let li = lines[i].trimmingCharacters(in: .whitespaces)
                    guard li.hasPrefix("- ") || li.hasPrefix("* ") else { break }
                    items.append(String(li.dropFirst(2))); i += 1
                }
                blocks.append(.bullet(items)); continue
            }
            if t.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {   // ordered list
                flush()
                var items: [String] = []
                while i < lines.count {
                    let li = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let r = li.range(of: #"^\d+\.\s"#, options: .regularExpression) else { break }
                    items.append(String(li[r.upperBound...])); i += 1
                }
                blocks.append(.ordered(items)); continue
            }
            if t.isEmpty { flush() } else { paragraph.append(line) }
            i += 1
        }
        flush()
        return blocks
    }
}

/// One ⌘K command palette action. `run` executes after the palette dismisses.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let icon: String
    let run: () -> Void
}

/// ⌘K command palette: a searchable list of actions with arrow-key navigation
/// and Enter to run. Filters by title; runs the selected command after closing.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var matches: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.paletteCommands()
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.inkFaint)
                TextField("Søg handlinger…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.ink).tint(Theme.accent)
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { runSelected(); return .handled }
                    .onKeyPress(.escape) { model.showCommandPalette = false; return .handled }
            }
            .padding(14)
            Divider().overlay(Theme.border)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { idx, cmd in
                            HStack(spacing: 10) {
                                Image(systemName: cmd.icon).font(.system(size: 13))
                                    .foregroundStyle(idx == selection ? Theme.onAccent : Theme.inkSoft).frame(width: 18)
                                Text(cmd.title).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(idx == selection ? Theme.onAccent : Theme.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(idx == selection ? Theme.accent : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                            .id(idx)
                            .onTapGesture { selection = idx; runSelected() }
                        }
                        if matches.isEmpty {
                            Text("Ingen handlinger").font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 460)
        .background(Theme.surface)
        .preferredColorScheme(model.colorScheme)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onExitCommand { model.showCommandPalette = false }   // Esc closes (robust)
    }

    private func move(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selection = max(0, min(selection + delta, count - 1))
    }

    private func runSelected() {
        let cmds = matches
        guard cmds.indices.contains(selection) else { return }
        let cmd = cmds[selection]
        model.showCommandPalette = false
        DispatchQueue.main.async { cmd.run() }   // run after the palette closes
    }
}

/// Manage the project's npm dependencies — list, add (npm install), remove
/// (npm uninstall). Add/remove restarts the dev server so the preview updates.
struct DependenciesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox").font(.system(size: 13)).foregroundStyle(Theme.accent)
                Text("Afhængigheder").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                if model.isManagingDeps { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Spacer()
                Button("Luk") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.inkSoft)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Theme.border)

            HStack(spacing: 8) {
                TextField("Pakkenavn (fx zustand, date-fns)", text: $model.newDependency)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.ink).tint(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusS).strokeBorder(Theme.border))
                    .onSubmit { model.addDependency() }
                Button { model.addDependency() } label: {
                    Text("Tilføj").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isManagingDeps || model.newDependency.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.dependencies) { dep in
                        HStack(spacing: 8) {
                            Text(dep.name).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink)
                            if dep.isDev {
                                Text("dev").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.inkFaint)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.fill, in: Capsule())
                            }
                            Spacer(minLength: 0)
                            Button { model.removeDependency(dep.name) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                                    .foregroundStyle(Theme.inkFaint)
                            }
                            .buttonStyle(.plain).disabled(model.isManagingDeps)
                            .help("Fjern \(dep.name)")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 440, height: 480)
        .background(Theme.canvas)
        .preferredColorScheme(model.colorScheme)
        .task { await model.loadDependencies() }
    }
}

/// Dialog to wire a Supabase backend (DB + auth) into the project: the user
/// pastes their project URL + public anon key; Forge scaffolds the client.
struct SupabaseDialogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tilføj backend (Supabase)")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Forge sætter en Supabase-klient op til database + login. Indsæt dit projekts URL og **anon**-nøgle (Supabase → Project Settings → API). Anon-nøglen er offentlig — ikke service-role-nøglen.")
                    .font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field("Project URL", "https://xxxxx.supabase.co", $model.supabaseURL)
            field("Anon key", "eyJhbGciOi…", $model.supabaseAnonKey)
            HStack {
                Button("Annuller") { dismiss() }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                Spacer()
                Button { model.addSupabaseBackend() } label: {
                    Text("Tilføj backend").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18).padding(.vertical, 8).background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isManagingDeps
                          || model.supabaseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.supabaseAnonKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .preferredColorScheme(model.colorScheme)
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkFaint)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.ink).tint(Theme.accent)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusS).strokeBorder(Theme.border))
        }
    }
}

/// Dialog for renaming the current project (from the project menu's "Omdøb…").
struct RenameDialogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("Omdøb projekt")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
            TextField("Projektnavn", text: $model.renameText)
                .textFieldStyle(.plain).font(.system(size: 15))
                .foregroundStyle(Theme.ink).tint(Theme.accent)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
                .onSubmit { model.commitRename() }
            HStack {
                Button("Annuller") { model.projectToRename = nil; dismiss() }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                Spacer()
                Button { model.commitRename() } label: {
                    Text("Gem").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .preferredColorScheme(model.colorScheme)
    }
}

/// Plan / Build segmented toggle for the composer. Plan mode makes the agent
/// propose a plan + ask questions instead of writing code.
struct ModeToggle: View {
    @Binding var mode: AgentLoop.Mode

    var body: some View {
        HStack(spacing: 2) {
            segment("Build", .build, icon: "hammer")
            segment("Plan", .plan, icon: "list.bullet.clipboard")
        }
        .padding(2)
        .background(Theme.fill, in: Capsule())
    }

    private func segment(_ title: String, _ value: AgentLoop.Mode, icon: String) -> some View {
        let selected = mode == value
        return Button { mode = value } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Theme.onAccent : Theme.inkSoft)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Theme.accent : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Clarifying questions from plan mode, rendered as tappable option chips.
struct QuestionChips: View {
    let questions: [PlanQuestion]
    var disabled: Bool
    var onAnswer: (PlanQuestion, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Image(systemName: "questionmark.circle").font(.system(size: 11))
                        Text(question.question).font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.ink)
                    FlowLayout(spacing: 6) {
                        ForEach(question.options, id: \.self) { option in
                            Button { onAnswer(question, option) } label: {
                                Text(option)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(Theme.fill, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(disabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact model selector, grouped by source (Ollama / LM Studio / Cloud) with
/// a colored dot per source and a Refresh action.
struct ModelPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            sourceSection(.ollama, "Ollama")
            sourceSection(.lmStudio, "LM Studio")
            sourceSection(.cloud, "Cloud")
            Divider()
            Button { Task { await model.refreshModels() } } label: {
                Label("Refresh models", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Self.dotColor(model.selectedModel.source)).frame(width: 6, height: 6)
                Text(model.selectedModel.displayName)
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.fill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func sourceSection(_ source: ModelConfig.Source, _ title: String) -> some View {
        let items = model.availableModels.filter { $0.source == source }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { config in
                    Button { model.selectedModelID = config.id } label: {
                        if config.id == model.selectedModelID {
                            Label(config.displayName, systemImage: "checkmark")
                        } else {
                            Text(config.displayName)
                        }
                    }
                }
            }
        }
    }

    static func dotColor(_ source: ModelConfig.Source) -> Color {
        switch source {
        case .ollama: Theme.positive
        case .lmStudio: Color.purple
        case .cloud: Color.blue
        }
    }
}

/// Small monospace file pill shown under an assistant message.
struct FileChip: View {
    let path: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text").font(.system(size: 10))
            Text(path).font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(Theme.inkSoft)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Project switcher: lists projects, switch, new, delete current.
struct ProjectMenu: View {
    @Bindable var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            ForEach(model.projects) { project in
                Button { model.switchTo(project) } label: {
                    if project.id == model.currentProject.id {
                        Label(displayName(project), systemImage: "checkmark")
                    } else {
                        Text(displayName(project))
                    }
                }
            }
            Divider()
            Button { model.newProject() } label: { Label("New project", systemImage: "plus") }
            if model.hasStarted {
                Button { model.beginRename(model.currentProject) } label: {
                    Label("Omdøb…", systemImage: "pencil")
                }
                Button { model.openInEditor() } label: {
                    Label("Open in editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { model.revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { model.exportZip() } label: { Label("Export as Zip…", systemImage: "archivebox") }
                Button { model.showDependencies = true } label: {
                    Label("Afhængigheder…", systemImage: "shippingbox")
                }
                Button { model.showSupabaseDialog = true } label: {
                    Label("Tilføj backend (Supabase)…", systemImage: "cylinder.split.1x2")
                }
            }
            if model.projects.count > 1 {
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Slet “\(displayName(model.currentProject))”", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(displayName(model.currentProject))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.fill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(model.isBusy)
        .confirmationDialog("Slet “\(displayName(model.currentProject))”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Slet projekt", role: .destructive) { model.deleteProject(model.currentProject) }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Projektets kode, chat og historik slettes permanent. Dette kan ikke fortrydes.")
        }
    }

    private func displayName(_ project: Project) -> String {
        project.name.isEmpty ? "Untitled" : project.name
    }
}

/// Keyboard-shortcut cheat sheet (⌘/ or the ? button). A quick reference for the
/// app's shortcuts so they're discoverable instead of hidden in the menu bar.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    private let groups: [(String, [(key: String, label: String)])] = [
        ("Generelt", [("⌘K", "Kommando-palette"), ("⌘N", "Nyt projekt"),
                      ("⌘,", "Indstillinger"), ("⌘.", "Stop generering"), ("esc", "Luk dialog / palette")]),
        ("Chat", [("⌘↩", "Send besked")]),
        ("Kode & preview", [("⌘\\", "Skift kode / preview"), ("⌘S", "Gem fil"),
                            ("⌘R", "Genindlæs preview"), ("⌘/", "Vis denne genvejsoversigt")]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "keyboard").font(.system(size: 13)).foregroundStyle(Theme.accent)
                Text("Tastaturgenveje").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Luk") { dismiss() }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkSoft)
                    .keyboardShortcut(.cancelAction)   // esc closes the sheet (as it advertises)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0.uppercased())
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkFaint)
                            ForEach(group.1, id: \.key) { row in
                                HStack(spacing: 12) {
                                    Text(row.label).font(.system(size: 13)).foregroundStyle(Theme.ink)
                                    Spacer(minLength: 0)
                                    KeyCap(row.key)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 380, height: 440)
        .background(Theme.canvas)
        .preferredColorScheme(model.colorScheme)
    }
}

private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }
}

/// A horizontal split whose divider position is draggable AND remembered across
/// launches (@AppStorage). Replaces HSplitView, which can't persist its position.
struct PersistentHSplit<Left: View, Right: View>: View {
    @AppStorage("forge.split.chatFraction") private var fraction: Double = 0.42
    let minLeft: CGFloat
    let maxLeft: CGFloat
    let minRight: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let upper = min(maxLeft, total - minRight)
            let leftW = max(minLeft, min(upper, total * fraction))
            HStack(spacing: 0) {
                left.frame(width: leftW)
                ZStack {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    // 16pt invisible grab-zone — a 1px line is too thin to grab comfortably.
                    Color.clear.frame(width: 16).contentShape(Rectangle())
                        .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let start = dragStart ?? Double(leftW)
                                    if dragStart == nil { dragStart = start }
                                    let newLeft = start + Double(value.translation.width)
                                    fraction = min(max(newLeft / Double(total), Double(minLeft) / Double(total)),
                                                   Double(upper) / Double(total))
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
                right.frame(maxWidth: .infinity)
            }
        }
    }
}
