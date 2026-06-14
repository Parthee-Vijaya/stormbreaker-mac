import SwiftUI

/// The first screen: a centered prompt, no preview yet. The preview pane only
/// appears once a build starts (`model.hasStarted`).
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    private let examples = ["Todo app with checkboxes", "Pomodoro timer", "Markdown notes", "Pricing page"]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(Theme.accent).frame(width: 9, height: 9)
                ProjectMenu(model: model)
                Spacer()
                ModelPicker(model: model)
            }
            .padding(14)

            Spacer()

            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Forge")
                        .font(Theme.wordmark(44))
                        .foregroundStyle(Theme.ink)
                    Text("Describe an app and watch it build — live.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.inkSoft)
                }

                Composer(
                    text: $model.draft,
                    placeholder: model.chatMode == .plan
                        ? "Describe what to plan…"
                        : "Build a todo app with add, complete and delete…",
                    isBusy: model.isBusy,
                    autofocus: true,
                    mode: $model.chatMode,
                    onSubmit: { model.submit() }
                )
                .frame(maxWidth: 560)

                FlowLayout(spacing: 8) {
                    ForEach(examples, id: \.self) { example in
                        Button {
                            model.draft = example
                            model.submit()
                        } label: {
                            Text(example)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.inkSoft)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.fill, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560, alignment: .center)
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
