import SwiftUI
import ForgeKit

struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header(model)
            Divider().overlay(Theme.border)
            messageList
            if model.showConsole {
                Divider().overlay(Theme.border)
                LogConsoleView().frame(height: 150)
            }
            Divider().overlay(Theme.border)
            VStack(spacing: 8) {
                if let element = model.selectedElement {
                    HStack(spacing: 6) {
                        Image(systemName: "cursorarrow.rays").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(element.text.isEmpty ? element.tag : "\(element.tag) · \(element.text)")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Button { model.clearSelection() } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.fill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
                }
                Composer(
                    text: $model.draft,
                    placeholder: model.selectedElement != nil
                        ? "Change the selected \(model.selectedElement!.tag)…"
                        : "Describe a change…",
                    isBusy: model.isBusy,
                    onSubmit: {
                        if model.selectedElement != nil { model.applyVisualEdit(model.draft) }
                        else { model.submit() }
                    },
                    onStop: { model.cancelGeneration() }
                )
            }
            .padding(12)
        }
        .background(Theme.sidebar)
    }

    private func header(_ model: AppModel) -> some View {
        HStack(spacing: 9) {
            Circle().fill(Theme.accent).frame(width: 9, height: 9)
            ProjectMenu(model: model)
            Spacer()
            ModelPicker(model: model)
            Button { model.showConsole.toggle() } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(IconButtonStyle())
            .help("Dev server console")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.sidebar)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { MessageView(message: $0) }
                    if model.isBusy { StatusRow(text: model.statusText) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: model.messages.last?.text) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.isBusy) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct MessageView: View {
    let message: AppModel.UIMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.onAccent)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if message.text.isEmpty {
                    Text("Working…").font(.system(size: 13.5)).foregroundStyle(Theme.inkFaint)
                } else {
                    Text(Self.render(message.text))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.files.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(message.files, id: \.self) { FileChip(path: $0) }
                    }
                }
            }
        }
    }

    static func render(_ text: String) -> AttributedString {
        let cleaned = text.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]*", with: "", options: .regularExpression)
        if let attributed = try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(cleaned)
    }
}

private struct StatusRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.fill, in: Capsule())
    }
}
