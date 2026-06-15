import Foundation

/// B11: the pluggable-agent-backend seam. Forge's own `AgentLoop` is the default
/// engine; this protocol is the contract any alternative backend (Claude Agent
/// SDK, Aider, Cline, …) would implement — translating that tool's output into
/// ForgeKit's `AgentEvent` stream so the app, parser and UI stay backend-agnostic.
///
/// START (this commit): the protocol, `AgentLoop`'s conformance, and the factory
/// seam are in place, and `AppModel` constructs its engine through the factory.
/// Concrete external adapters (which need the tool installed + their own output
/// parsing) are the remaining work; selecting one falls back to the built-in loop
/// so the app never breaks.
public protocol ForgeEngine: Sendable {
    func run(
        userPrompt: String,
        history: [ChatMessage],
        mode: AgentLoop.Mode,
        images: [String]
    ) -> AsyncStream<AgentEvent>
}

extension AgentLoop: ForgeEngine {}

/// Which agent backend powers a build turn. Only `.forge` is wired today; the rest
/// name the intended extension points (see `ForgeEngine`).
public enum EngineKind: String, Sendable, CaseIterable {
    case forge          // Forge's built-in AgentLoop (default)
    case claudeSDK      // future: Claude Agent SDK adapter
    case aider          // future: Aider CLI adapter
    case cline          // future: Cline adapter

    public var displayName: String {
        switch self {
        case .forge: "Forge (indbygget)"
        case .claudeSDK: "Claude Agent SDK"
        case .aider: "Aider"
        case .cline: "Cline"
        }
    }
}

public enum ForgeEngineFactory {
    /// Build the engine for a backend kind. Any backend whose adapter isn't
    /// implemented yet falls back to the built-in `AgentLoop`, so selecting one
    /// never breaks a build.
    public static func make(_ kind: EngineKind, deps: AgentLoop.Dependencies) -> any ForgeEngine {
        switch kind {
        case .forge: AgentLoop(deps)
        default: AgentLoop(deps)   // external adapters not implemented yet
        }
    }
}
