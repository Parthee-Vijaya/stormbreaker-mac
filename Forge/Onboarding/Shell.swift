import Foundation

/// Runs a command through the user's login shell (so it inherits the full PATH —
/// gh/vercel live in /opt/homebrew/bin which a GUI app doesn't get by default).
/// Read-only detection use in onboarding (gh auth status, vercel whoami, …).
enum Shell {
    static func login(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-ilc", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
