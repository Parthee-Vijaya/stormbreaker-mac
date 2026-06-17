import Foundation

/// A side-effectful action the user may want to approve before it runs. Only the
/// three "escape hatches" are gated — file writes are already checkpointed,
/// diffable and restorable, and `start` (npm run dev) is inert.
public enum PermissionRequest: Sendable, Equatable {
    case shell(command: String)
    case addDependencies([String])
    case mcp(server: String, tool: String)

    /// A human-readable one-line description, for prompts + deny-feedback.
    public var label: String {
        switch self {
        case .shell(let command):
            return "køre kommandoen: \(command)"
        case .addDependencies(let packages):
            return "installere pakke(r): \(packages.joined(separator: ", "))"
        case .mcp(let server, let tool):
            return "kalde det eksterne værktøj: \(server)/\(tool)"
        }
    }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow            // run this once
    case allowForSession  // run + don't ask again this session (the gate remembers)
    case deny             // skip it
}

/// Approves or denies side-effectful actions before they run. The gate owns any
/// "remember for this session" behaviour; callers treat `allow`/`allowForSession`
/// the same (proceed) and `deny` as skip.
public protocol PermissionGate: Sendable {
    func decide(_ request: PermissionRequest) async -> PermissionDecision
}
