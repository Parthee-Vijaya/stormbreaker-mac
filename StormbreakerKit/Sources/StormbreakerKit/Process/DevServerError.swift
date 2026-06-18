import Foundation

/// Typed failures from the process / dev-server layer. Each case carries enough
/// context (searched paths, log tails) for the UI to tell the user what went
/// wrong without digging through raw output.
public enum DevServerError: Error, Sendable, Equatable {
    case nodeRuntimeNotFound(searched: [String])
    case packageManagerNotFound(name: String)
    case installFailed(exitCode: Int32, tail: [LogLine])
    case serverFailedToStart(tail: [LogLine])
    case readyTimedOut(seconds: Int)
    case projectDirectoryUnwritable(path: String)
    case alreadyRunning
}

extension DevServerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nodeRuntimeNotFound(let searched):
            return "Node runtime not found. Searched: \(searched.joined(separator: ", "))"
        case .packageManagerNotFound(let name):
            return "Package manager '\(name)' not found on PATH."
        case .installFailed(let code, let tail):
            // Surface the ACTUAL npm output (peer-dep conflict, network, ENOENT, …)
            // — not just the exit code — so the user/agent can see what failed.
            return "Dependency install failed (exit code \(code))." + Self.detail(tail)
        case .serverFailedToStart(let tail):
            return "The dev server exited before it became ready." + Self.detail(tail)
        case .readyTimedOut(let seconds):
            return "Timed out after \(seconds)s waiting for the dev server to start."
        case .projectDirectoryUnwritable(let path):
            return "Project directory is not writable: \(path)"
        case .alreadyRunning:
            return "The dev server is already running."
        }
    }

    /// The last few non-empty log lines, formatted for inline display.
    private static func detail(_ tail: [LogLine], max: Int = 8) -> String {
        let lines = tail.suffix(max).map { $0.text }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }
}
