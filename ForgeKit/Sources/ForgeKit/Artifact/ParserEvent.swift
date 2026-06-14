import Foundation

/// Events emitted incrementally by `StreamingArtifactParser` as tokens stream
/// in. `text` is prose for the chat pane; the rest drive the action executor
/// and (optionally) preview-progress UI.
public enum ParserEvent: Sendable, Equatable {
    case text(String)                              // prose outside any artifact
    case artifactOpen(id: String, title: String)
    case fileOpen(path: String)
    case fileChunk(path: String, text: String)     // streamed file content (UI progress)
    case fileClose(path: String, contents: String) // file complete → write it now
    case lineReplaceOpen(path: String)             // a search/replace edit begins
    case lineReplaceClose(path: String, edits: [LineEdit]) // edits parsed → apply now
    case inlineAction(ForgeAction)                  // shell / start / add-dependency (queued)
    case artifactClose
}
