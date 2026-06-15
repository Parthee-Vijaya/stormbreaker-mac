import SwiftUI

/// Popover shown from the Deploy button: status, GitHub + Vercel links, log.
struct DeployPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.isDeploying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.deployLiveURL != nil ? "checkmark.circle.fill" : "arrowtriangle.up.circle")
                        .foregroundStyle(model.deployLiveURL != nil ? Theme.positive : Theme.ink)
                }
                Text(headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            }

            if !model.isDeploying {
                Picker("", selection: $model.preferences.deployTarget) {
                    Text("Vercel").tag("vercel")
                    Text("Netlify").tag("netlify")
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: model.preferences.deployTarget) { model.savePreferences() }

                Text("Eksperimentel — kræver \(model.preferences.deployTarget == "netlify" ? "netlify" : "vercel")-CLI installeret og logget ind (samt gh til GitHub-push).")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let github = model.deployGithubURL {
                linkRow(label: "GitHub repo", url: github, icon: "chevron.left.forwardslash.chevron.right")
            }
            if let vercel = model.deployLiveURL {
                linkRow(label: "Live URL", url: vercel, icon: "globe")
            }

            if !model.deployLog.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.deployLog.suffix(80).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.inkFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 130)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
            }

            if !model.isDeploying {
                Button { model.deploy() } label: {
                    Text(model.deployLiveURL != nil ? "Redeploy" : "Deploy")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            // B16: Vercel deploy history + one-click rollback (shown whenever the
            // Vercel target is selected, so the rollback affordance is discoverable).
            if model.preferences.deployTarget == "vercel", !model.isDeploying {
                Divider().overlay(Theme.border)
                HStack {
                    Text("Tidligere deploys")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkFaint)
                    Spacer()
                    Button { model.fetchDeployHistory() } label: {
                        if model.isFetchingDeploys { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkSoft).disabled(model.isFetchingDeploys)
                }
                if model.deployHistory.isEmpty {
                    Text(model.isFetchingDeploys ? "Henter…"
                         : "Ingen deploys fundet — deploy først, eller tjek at `vercel` er logget ind.")
                        .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(model.deployHistory) { deployment in
                                deployHistoryRow(deployment)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            if model.preferences.deployTarget == "vercel",
               model.deployLiveURL != nil, model.deployHistory.isEmpty {
                model.fetchDeployHistory()
            }
        }
    }

    private func deployHistoryRow(_ d: AppModel.Deployment) -> some View {
        let isCurrent = model.deployLiveURL?.absoluteString == d.url.absoluteString
        return HStack(spacing: 8) {
            Circle()
                .fill(d.state == "Ready" ? Theme.positive : d.state == "Error" ? Color.red : Theme.inkFaint)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.url.host ?? d.url.absoluteString)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                    .lineLimit(1).truncationMode(.middle)
                Text(d.age.isEmpty ? d.state : "\(d.age) · \(d.state)")
                    .font(.system(size: 9.5)).foregroundStyle(Theme.inkFaint)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Text("nu").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.positive)
            } else {
                Button { model.rollbackTo(d) } label: {
                    Text("Rul tilbage").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).disabled(model.isDeploying)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isCurrent ? Theme.accent.opacity(0.10) : Theme.fill, in: RoundedRectangle(cornerRadius: 7))
    }

    private var headline: String {
        if model.isDeploying { return model.deployStatus.isEmpty ? "Deploying…" : model.deployStatus }
        if model.deployLiveURL != nil { return "Deployed 🎉" }
        return "Deploy → GitHub + \(model.preferences.deployTarget == "netlify" ? "Netlify" : "Vercel")"
    }

    private func linkRow(label: String, url: URL, icon: String) -> some View {
        Button { model.openURL(url) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.inkSoft).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                    Text(url.absoluteString)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward").font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            }
            .padding(10)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
