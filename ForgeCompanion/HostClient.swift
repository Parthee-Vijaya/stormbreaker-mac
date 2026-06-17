import Foundation
import Observation

/// The status snapshot the Mac's RemoteServer serves at GET /status.
/// Lenient decode so the initial empty `{}` (before a project is open) is fine.
struct HostStatus: Equatable {
    var projectName = ""
    var framework = ""
    var previewURL = ""
    var hasStarted = false
}

extension HostStatus: Decodable {
    enum CodingKeys: String, CodingKey { case projectName, framework, previewURL, hasStarted }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        framework = try c.decodeIfPresent(String.self, forKey: .framework) ?? ""
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL) ?? ""
        hasStarted = try c.decodeIfPresent(Bool.self, forKey: .hasStarted) ?? false
    }
}

/// Polls the Mac's RemoteServer and exposes a reachable preview URL.
@MainActor
@Observable
final class HostClient {
    enum Connection: Equatable { case idle, connecting, connected, failed(String) }

    var host: String = UserDefaults.standard.string(forKey: "forge-host") ?? ""
    var connection: Connection = .idle
    var token: String = UserDefaults.standard.string(forKey: "forge-token") ?? ""   // Fase 4c: steer token
    var status = HostStatus()
    var lastAction: String?                 // feedback after a steer POST
    private var task: Task<Void, Never>?

    /// The Mac serves the dev server on its own 127.0.0.1, so the phone must hit the
    /// Mac's LAN/Tailscale address instead. Keep the port, swap the host.
    var reachablePreviewURL: URL? {
        guard status.hasStarted, !status.previewURL.isEmpty,
              var comps = URLComponents(string: status.previewURL), !hostOnly.isEmpty
        else { return nil }
        comps.host = hostOnly
        return comps.url
    }

    /// Accepts "192.168.1.50", "192.168.1.50:7842" or "http://192.168.1.50".
    private var hostOnly: String {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        h = h.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        return String(h.split(separator: "/").first?.split(separator: ":").first ?? "")
    }

    private var statusURL: URL? {
        hostOnly.isEmpty ? nil : URL(string: "http://\(hostOnly):7842/status")
    }

    func connect() {
        UserDefaults.standard.set(host, forKey: "forge-host")
        task?.cancel()
        connection = .connecting
        task = Task { await pollLoop() }
    }

    func disconnect() {
        task?.cancel(); task = nil
        connection = .idle
    }

    private func pollLoop() async {
        guard let url = statusURL else { connection = .failed("Ugyldig adresse"); return }
        while !Task.isCancelled {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 4
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                status = try JSONDecoder().decode(HostStatus.self, from: data)
                connection = .connected
            } catch {
                if Task.isCancelled { return }
                connection = .failed(friendly(error))
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func friendly(_ error: Error) -> String {
        switch (error as NSError).code {
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
             NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "Kan ikke nå Mac'en. Kører Forge, og er du på samme netværk/Tailscale?"
        default:
            return (error as NSError).localizedDescription
        }
    }

    // MARK: - Steer (Fase 4c)

    /// POST a steer command to the Mac (requires the shared token from the Mac's
    /// "Del til iPhone" toast). build/stop/restore map to RemoteServer's endpoints.
    func steer(_ path: String, body: [String: Any] = [:]) {
        UserDefaults.standard.set(token, forKey: "forge-token")
        guard !hostOnly.isEmpty, let url = URL(string: "http://\(hostOnly):7842/\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue(token, forHTTPHeaderField: "X-Forge-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lastAction = code == 200 ? "Sendt ✓" : (code == 401 ? "Forkert token" : "Fejl (\(code))")
            } catch { lastAction = "Kunne ikke sende" }
        }
    }
    func build(_ prompt: String) { steer("build", body: ["prompt": prompt]) }
    func stopBuild() { steer("stop") }
    func restore() { steer("restore") }
}
