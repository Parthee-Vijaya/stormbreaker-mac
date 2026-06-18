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
    case inlineAction(StormbreakerAction)                  // shell / start / add-dependency (queued)
    case readRequest(path: String)                  // A2b: model asks to see a file's contents
    case mcpRequest(server: String, tool: String, arguments: String)  // model asks to call an MCP tool
    case webRequest(kind: WebRequestKind, query: String)  // model asks to fetch a URL or search the web
    case todoUpdate([TodoItem])                     // model emitted/updated its plan checklist
    case artifactClose
}

/// What the model wants from the web tool: fetch a specific URL, or run a search.
public enum WebRequestKind: Sendable, Equatable { case fetch, search }
