import SwiftUI

struct CompanionView: View {
    @State private var client = HostClient()
    @State private var prompt = ""   // Fase 4c: steer prompt

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Forge")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if client.connection == .connected {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Skift Mac") { client.disconnect() }
                        }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if client.connection == .connected {
            connected
        } else {
            connect
        }
    }

    private var connect: some View {
        @Bindable var client = client
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hammer.fill").font(.system(size: 46)).foregroundStyle(.tint)
            Text("Forbind til din Mac").font(.title2.bold())
            Text("Skriv din Macs adresse — LAN-IP eller Tailscale. Forge skal køre på Mac'en.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            TextField("fx 192.168.1.50 eller 100.x.y.z", text: $client.host)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(client.connect)
            TextField("Token (valgfri — kun for at styre Mac'en)", text: $client.token)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(action: client.connect) {
                Text(client.connection == .connecting ? "Forbinder…" : "Forbind")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(client.host.trimmingCharacters(in: .whitespaces).isEmpty || client.connection == .connecting)
            if case .failed(let msg) = client.connection {
                Text(msg).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer(); Spacer()
        }
        .padding()
    }

    private var connected: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(client.status.projectName.isEmpty ? "Intet projekt åbent" : client.status.projectName)
                        .font(.headline)
                    Text(client.status.framework.isEmpty ? client.host
                         : "\(client.status.framework) · \(client.host)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            if let url = client.reachablePreviewURL {
                PreviewWebView(url: url).ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    "Ingen kørende preview",
                    systemImage: "play.slash",
                    description: Text("Start et build på din Mac, så viser den sig live her.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) { steerBar }
    }

    /// Fase 4c: drive the Mac from the phone — send a prompt or stop the build.
    /// Needs the token entered on the connect screen (else the Mac returns 401).
    private var steerBar: some View {
        @Bindable var client = client
        return VStack(spacing: 5) {
            if let action = client.lastAction {
                Text(action).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("Beskriv en ændring…", text: $prompt)
                    .textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || client.token.isEmpty)
                Button { client.stopBuild() } label: { Image(systemName: "stop.circle").font(.title2) }
                    .tint(.red).disabled(client.token.isEmpty)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func send() {
        let p = prompt.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        client.build(p)
        prompt = ""
    }
}
