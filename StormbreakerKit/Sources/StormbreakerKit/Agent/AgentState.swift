import Foundation

/// Coarse state of one agent turn, surfaced to the UI.
public enum AgentState: Sendable, Equatable {
    case idle
    case building            // streaming model output + applying actions
    case applying            // running install/start at artifact close
    case awaitingHMR         // edits applied; waiting for Vite/console to settle
    case collectingErrors
    case repairing(attempt: Int)
    case clean               // converged: app runs with no errors
    case failed(String)
    case planning            // plan mode: streaming a plan, no files written
    case planReady           // plan mode: plan complete, awaiting the user
}

/// Per model-call performance metrics (verbose/observability): tokens, time to
/// first token, total time, and derived throughput. One per provider response.
public struct GenerationMetrics: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Seconds from request start to the first streamed token (TTFT).
    public var timeToFirstTokenSeconds: Double?
    /// Total wall-clock seconds for the whole response.
    public var totalSeconds: Double

    public init(promptTokens: Int = 0, completionTokens: Int = 0,
                timeToFirstTokenSeconds: Double? = nil, totalSeconds: Double = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.totalSeconds = totalSeconds
    }

    public var totalTokens: Int { promptTokens + completionTokens }

    /// Output tokens per second (completion ÷ total time). 0 when unmeasurable.
    public var tokensPerSecond: Double {
        guard totalSeconds > 0, completionTokens > 0 else { return 0 }
        return Double(completionTokens) / totalSeconds
    }
}

/// Streamed output of `AgentLoop.run`. The app renders these into the chat,
/// the preview, and a status line.
public enum AgentEvent: Sendable {
    case assistantText(String)   // prose for the chat pane (artifact internals excluded)
    case reasoning(String)       // reasoning-model "thinking", shown collapsibly
    case state(AgentState)
    case fileWriting(String)
    case fileChunk(String, String)  // (path, text) — streamed file body for the live editor
    case fileWritten(String)
    case previewReady(URL)
    case usage(promptTokens: Int, completionTokens: Int)   // per provider response
    case metrics(GenerationMetrics)   // per provider response: tokens + TTFT + tok/s
    case todos([TodoItem])            // the agent's live plan checklist (todowrite-style)
}

extension Duration {
    /// This `Duration` as fractional seconds (for metrics formatting).
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
