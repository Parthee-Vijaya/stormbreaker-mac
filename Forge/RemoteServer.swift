import Foundation
import Network

/// B19 (host side): a tiny HTTP server the iOS companion app polls over LAN /
/// Tailscale to mirror the Mac's current project — its name, framework and live
/// dev-server preview URL. AppModel pushes a status snapshot whenever it changes;
/// the listener serves that snapshot (a pre-rendered JSON string), so connection
/// handlers never touch @MainActor state. Bound to 0.0.0.0:<port> so a phone on the
/// same network (or Tailscale) can reach it.
///
/// START: the host serves GET /status (+ /health). The SwiftUI iOS app target that
/// consumes it — load the previewURL in a WKWebView, send prompts back — is the
/// remaining XL piece.
/// Fase 4c: a steer command from the iOS companion (or a curl) to a sharing-enabled
/// host. Read-only `/status` stays open; these POST verbs require the shared token.
enum RemoteCommand: Sendable, Equatable {
    case build(String)
    case stop
    case restore
}

final class RemoteServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private let lock = NSLock()
    private var statusJSON = "{}"
    private var authToken: String?                       // required for POST (steer) endpoints
    var onCommand: (@Sendable (RemoteCommand) -> Void)?  // build/stop/restore → AppModel
    private(set) var isRunning = false

    init(port: UInt16 = 7842) { self.port = port }

    /// Update the snapshot served at /status (called from AppModel on the main actor).
    func setStatus(_ object: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        lock.lock(); statusJSON = json; lock.unlock()
    }

    /// Set the shared token that POST (steer) endpoints require. nil = steering off.
    func setAuthToken(_ token: String?) { lock.lock(); authToken = token; lock.unlock() }

    private func currentStatus() -> String {
        lock.lock(); defer { lock.unlock() }; return statusJSON
    }
    private func currentToken() -> String? {
        lock.lock(); defer { lock.unlock() }; return authToken
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let method = Self.requestMethod(request)
            let path = Self.requestPath(request)
            var status = "200 OK"
            var body = "{}"

            if method == "POST" {
                // Steer endpoints: require sharing-with-token enabled + a matching token.
                let provided = Self.header("x-forge-token", in: request)
                guard let expected = self.currentToken(), !expected.isEmpty, provided == expected else {
                    self.respond(connection, status: "401 Unauthorized", body: #"{"error":"unauthorized"}"#)
                    return
                }
                switch path {
                case "/build":
                    let prompt = Self.jsonField("prompt", in: Self.requestBody(request)) ?? ""
                    if prompt.isEmpty {
                        status = "400 Bad Request"; body = #"{"error":"empty prompt"}"#
                    } else {
                        self.onCommand?(.build(prompt)); body = #"{"ok":true}"#
                    }
                case "/stop":    self.onCommand?(.stop); body = #"{"ok":true}"#
                case "/restore": self.onCommand?(.restore); body = #"{"ok":true}"#
                default: status = "404 Not Found"; body = #"{"error":"not found"}"#
                }
            } else {
                switch path {
                case "/status": body = self.currentStatus()
                case "/health": body = #"{"ok":true}"#
                default: status = "404 Not Found"; body = #"{"error":"not found"}"#
                }
            }
            self.respond(connection, status: status, body: body)
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + bodyData,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Extract the path from an HTTP request line ("GET /status HTTP/1.1").
    private static func requestPath(_ request: String) -> String {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return "/" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1].split(separator: "?").first ?? "/")
    }

    private static func requestMethod(_ request: String) -> String {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return "" }
        return String(line.split(separator: " ").first ?? "")
    }

    /// Read a request header value (case-insensitive name).
    private static func header(_ name: String, in request: String) -> String? {
        let lower = name.lowercased()
        for line in request.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == lower else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The body after the blank line. (Small JSON bodies arrive in one packet; a
    /// multi-packet body isn't reassembled — fine for short steer prompts.)
    private static func requestBody(_ request: String) -> String {
        guard let range = request.range(of: "\r\n\r\n") else { return "" }
        return String(request[range.upperBound...])
    }

    private static func jsonField(_ key: String, in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }
}
