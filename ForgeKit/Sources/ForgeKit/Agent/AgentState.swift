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
}
