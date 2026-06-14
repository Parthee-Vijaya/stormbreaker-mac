import SwiftUI
import ForgeKit

struct PreviewPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar()
            Divider().overlay(Theme.border)
            ZStack {
                Theme.fill
                // Keep the WebView mounted (opacity) so HMR + state survive a
                // switch to Code and back.
                previewLayer
                    .opacity(model.rightPaneMode == .preview ? 1 : 0)
                    .allowsHitTesting(model.rightPaneMode == .preview)
                if model.rightPaneMode == .code {
                    CodePane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
    }

    @ViewBuilder private var previewLayer: some View {
        if let url = model.previewURL {
            WebView(url: url, reloadToken: model.reloadToken, selectMode: model.selectMode,
                    onRuntimeIssue: { model.handleRuntimeIssue($0) },
                    onElementSelected: { model.handleElementSelected(tag: $0, text: $1, className: $2, selector: $3) })
                .frame(maxWidth: model.previewWidth.maxWidth ?? .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: model.previewWidth == .full ? 0 : 12))
                .shadow(color: model.previewWidth == .full ? .clear : .black.opacity(0.10),
                        radius: 16, y: 4)
                .padding(model.previewWidth == .full ? 0 : 24)
        } else {
            BuildingView(statusText: model.statusText, lastLog: model.serverLog.last?.text, isBusy: model.isBusy)
        }
    }
}

private struct PreviewToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                modeButton("Preview", .preview)
                modeButton("Code", .code)
            }
            .padding(2).background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))

            if model.rightPaneMode == .preview {
                deviceToggles
                urlPill
                Button { model.toggleSelectMode() } label: {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 12))
                        .foregroundStyle(model.selectMode ? Theme.onAccent : Theme.inkSoft)
                        .frame(width: 30, height: 28)
                        .background(model.selectMode ? Theme.accent : Theme.fill,
                                    in: RoundedRectangle(cornerRadius: Theme.radiusS))
                }
                .buttonStyle(.plain).disabled(model.previewURL == nil)
                .help("Select an element to edit")
                Button { model.reloadPreview() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle()).disabled(model.previewURL == nil)
                Button { model.openInBrowser() } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(IconButtonStyle()).disabled(model.previewURL == nil)
                Button { model.showDeploy = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowtriangle.up.circle.fill").font(.system(size: 11))
                        Text("Deploy").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.previewURL == nil)
                .popover(isPresented: $model.showDeploy, arrowEdge: .bottom) { DeployPanel() }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.canvas)
    }

    private func modeButton(_ title: String, _ mode: AppModel.RightPaneMode) -> some View {
        Button {
            if mode == .code { model.enterCodeMode() } else { model.rightPaneMode = .preview }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.rightPaneMode == mode ? Theme.ink : Theme.inkFaint)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(model.rightPaneMode == mode ? Theme.surface : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var deviceToggles: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.PreviewWidth.allCases, id: \.self) { width in
                Button { model.previewWidth = width } label: {
                    Image(systemName: width.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(model.previewWidth == width ? Theme.ink : Theme.inkFaint)
                        .frame(width: 26, height: 22)
                        .background(model.previewWidth == width ? Theme.surface : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }

    private var urlPill: some View {
        HStack(spacing: 6) {
            Circle().fill(model.previewURL != nil ? Theme.positive : Theme.inkFaint)
                .frame(width: 6, height: 6)
            Text(model.previewURL?.absoluteString ?? "starting dev server…")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Theme.fill, in: Capsule())
    }
}

private struct BuildingView: View {
    let statusText: String
    let lastLog: String?
    var isBusy: Bool = true

    var body: some View {
        VStack(spacing: 14) {
            Text("Forge")
                .font(Theme.wordmark(28))
                .foregroundStyle(Theme.ink.opacity(0.9))
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small) }
                Text(statusText).font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
            }
            if let lastLog, !lastLog.isEmpty {
                Text(lastLog)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkFaint)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 380)
            }
        }
        .padding(28)
    }
}
