import Foundation

/// Incrementally parses a Bolt/Lovable-style artifact out of a streamed token
/// sequence and emits `ParserEvent`s. Designed for whole-file writes:
///
/// ```
/// <forgeArtifact id="..." title="...">
///   <forgeAction type="add-dependency">clsx</forgeAction>
///   <forgeAction type="file" filePath="src/App.tsx">…full contents…</forgeAction>
///   <forgeAction type="start">npm run dev</forgeAction>
/// </forgeArtifact>
/// ```
///
/// Robustness rules:
/// - Acts only on FULLY-present delimiters. A trailing fragment that could be
///   the start of a delimiter is held in the buffer for the next chunk.
/// - In a file body, ONLY `</forgeAction>` terminates the file, so a stray `<`
///   or `</div>` inside JSX is safe.
/// - A file is written as soon as its closing tag arrives (write-as-you-go);
///   shell/start/add-dependency are queued for the executor.
///
/// Not thread-safe — drive it from a single task.
public final class StreamingArtifactParser {
    public enum State: Equatable {
        case idle
        case inArtifact
        case inActionTag
        case inFileBody(path: String)
        case inLineReplaceBody(path: String)
        case inInlineBody(type: String)
    }

    private var state: State = .idle
    private var buffer = ""
    private var fileContents = ""
    private var inlineBuffer = ""
    private var mcpServer = ""   // server/tool of the in-flight <forgeAction type="mcp">
    private var mcpTool = ""

    private static let artifactOpenMarker = "<forgeArtifact"
    private static let artifactCloseMarker = "</forgeArtifact>"
    private static let actionOpenMarker = "<forgeAction"
    private static let actionCloseMarker = "</forgeAction>"

    public init() {}

    public func consume(_ token: String) -> [ParserEvent] {
        buffer += token
        return drain(atEnd: false)
    }

    /// Flush at end of stream: held tails are emitted as-is.
    public func finish() -> [ParserEvent] {
        var events = drain(atEnd: true)
        // If the stream ended mid-file (e.g. the user cancelled before the closing
        // </forgeAction> arrived), the partial body was streamed as chunks but never
        // closed — so emit a final fileClose with what we have, instead of silently
        // losing the file. A partial line-replace is dropped, not applied: a half a
        // SEARCH/REPLACE block would corrupt the target file.
        switch state {
        case .inFileBody(let path):
            events.append(.fileClose(path: path, contents: stripCodeFence(trimEdges(fileContents))))
            fileContents = ""
            state = .inArtifact
        case .inLineReplaceBody:
            fileContents = ""
            state = .inArtifact
        default:
            break
        }
        return events
    }

    // MARK: - Core

    private func drain(atEnd: Bool) -> [ParserEvent] {
        var events: [ParserEvent] = []
        var progressing = true
        while progressing {
            progressing = false
            switch state {
            case .idle:
                progressing = drainIdle(&events, atEnd: atEnd)
            case .inArtifact:
                progressing = drainInArtifact(&events, atEnd: atEnd)
            case .inActionTag:
                progressing = drainActionTag(&events)
            case .inFileBody(let path):
                progressing = drainFileBody(path: path, &events, atEnd: atEnd)
            case .inLineReplaceBody(let path):
                progressing = drainLineReplaceBody(path: path, &events, atEnd: atEnd)
            case .inInlineBody(let type):
                progressing = drainInlineBody(type: type, &events, atEnd: atEnd)
            }
        }
        return events
    }

    private func drainIdle(_ events: inout [ParserEvent], atEnd: Bool) -> Bool {
        if let marker = buffer.range(of: Self.artifactOpenMarker) {
            let before = String(buffer[..<marker.lowerBound])
            if !before.isEmpty { events.append(.text(before)) }
            buffer = String(buffer[marker.lowerBound...])
            guard let gt = buffer.range(of: ">") else { return false } // wait for full tag
            let tag = String(buffer[..<gt.upperBound])
            events.append(.artifactOpen(id: attribute("id", in: tag) ?? "",
                                        title: attribute("title", in: tag) ?? ""))
            buffer = String(buffer[gt.upperBound...])
            state = .inArtifact
            return true
        }
        // No artifact start: emit text, holding a possible partial marker tail.
        let hold = atEnd ? "" : longestSuffixPrefix(of: buffer, matching: Self.artifactOpenMarker)
        let emit = String(buffer.dropLast(hold.count))
        if !emit.isEmpty { events.append(.text(emit)) }
        buffer = hold
        return false
    }

    private func drainInArtifact(_ events: inout [ParserEvent], atEnd: Bool) -> Bool {
        let close = buffer.range(of: Self.artifactCloseMarker)
        let action = buffer.range(of: Self.actionOpenMarker)
        switch (close, action) {
        case let (c?, a?):
            if c.lowerBound <= a.lowerBound { return takeArtifactClose(c, &events) }
            return takeActionOpen(a)
        case let (c?, nil):
            return takeArtifactClose(c, &events)
        case let (nil, a?):
            return takeActionOpen(a)
        case (nil, nil):
            // Drop inter-action whitespace/text, but hold a possible partial marker.
            buffer = atEnd ? "" : longestSuffixPrefix(
                of: buffer, matching: Self.actionOpenMarker, Self.artifactCloseMarker)
            return false
        }
    }

    private func takeArtifactClose(_ range: Range<String.Index>, _ events: inout [ParserEvent]) -> Bool {
        buffer = String(buffer[range.upperBound...])
        events.append(.artifactClose)
        state = .idle
        return true
    }

    private func takeActionOpen(_ range: Range<String.Index>) -> Bool {
        buffer = String(buffer[range.lowerBound...])
        state = .inActionTag
        return true
    }

    private func drainActionTag(_ events: inout [ParserEvent]) -> Bool {
        guard let gt = buffer.range(of: ">") else { return false } // wait for full opening tag
        let tag = String(buffer[..<gt.upperBound])
        buffer = String(buffer[gt.upperBound...])
        let type = attribute("type", in: tag) ?? ""
        if type == "file" {
            let path = attribute("filePath", in: tag) ?? ""
            fileContents = ""
            events.append(.fileOpen(path: path))
            state = .inFileBody(path: path)
        } else if type == "line-replace" {
            let path = attribute("filePath", in: tag) ?? ""
            fileContents = ""
            events.append(.lineReplaceOpen(path: path))
            state = .inLineReplaceBody(path: path)
        } else if type == "read-file" {
            // A2b: a request to see a file. Emit it now (path is in the attribute)
            // and consume the (empty) body until </forgeAction>.
            events.append(.readRequest(path: attribute("filePath", in: tag) ?? ""))
            inlineBuffer = ""
            state = .inInlineBody(type: "read-file")
        } else if type == "mcp" {
            // A request to call an external MCP tool: server/tool are attributes, the
            // body is the JSON arguments (emitted as .mcpRequest on close).
            mcpServer = attribute("server", in: tag) ?? ""
            mcpTool = attribute("tool", in: tag) ?? ""
            inlineBuffer = ""
            state = .inInlineBody(type: "mcp")
        } else {
            inlineBuffer = ""
            state = .inInlineBody(type: type)
        }
        return true
    }

    private func drainFileBody(path: String, _ events: inout [ParserEvent], atEnd: Bool) -> Bool {
        let actionClose = buffer.range(of: Self.actionCloseMarker)
        let artifactClose = buffer.range(of: Self.artifactCloseMarker)

        // Normal terminator: </forgeAction> (when it's present and comes first).
        if let close = actionClose, artifactClose == nil || close.lowerBound <= artifactClose!.lowerBound {
            let content = String(buffer[..<close.lowerBound])
            if !content.isEmpty {
                fileContents += content
                events.append(.fileChunk(path: path, text: content))
            }
            buffer = String(buffer[close.upperBound...])
            events.append(.fileClose(path: path, contents: stripCodeFence(trimEdges(fileContents))))
            fileContents = ""
            state = .inArtifact
            return true
        }

        // Robustness: the model omitted </forgeAction> and jumped straight to
        // </forgeArtifact>. That marker can never appear in real source, so treat it as
        // an implicit file-close — and LEAVE it in the buffer so `.inArtifact` closes the
        // artifact next. Without this the close tag leaks into the file (e.g. a Svelte
        // component ending "</div>\n</forgeArtifact>"), which then fails to compile.
        if let artClose = artifactClose {
            let content = String(buffer[..<artClose.lowerBound])
            if !content.isEmpty {
                fileContents += content
                events.append(.fileChunk(path: path, text: content))
            }
            buffer = String(buffer[artClose.lowerBound...])
            events.append(.fileClose(path: path, contents: stripCodeFence(trimEdges(fileContents))))
            fileContents = ""
            state = .inArtifact
            return true
        }

        // Stream content, holding a tail that could be a partial close tag of EITHER
        // kind (both start with "</storm").
        let hold = atEnd ? "" : longestSuffixPrefix(
            of: buffer, matching: Self.actionCloseMarker, Self.artifactCloseMarker)
        let emit = String(buffer.dropLast(hold.count))
        if !emit.isEmpty {
            fileContents += emit
            events.append(.fileChunk(path: path, text: emit))
        }
        buffer = hold
        return false
    }

    /// Captures a line-replace body exactly like a file body (raw, terminated
    /// only by `</forgeAction>` so diff markers and JSX are safe), then parses it
    /// into search/replace edits on close.
    private func drainLineReplaceBody(path: String, _ events: inout [ParserEvent], atEnd: Bool) -> Bool {
        if let close = buffer.range(of: Self.actionCloseMarker) {
            fileContents += String(buffer[..<close.lowerBound])
            buffer = String(buffer[close.upperBound...])
            let edits = Self.parseLineEdits(stripCodeFence(trimEdges(fileContents)))
            events.append(.lineReplaceClose(path: path, edits: edits))
            fileContents = ""
            state = .inArtifact
            return true
        }
        let hold = atEnd ? "" : longestSuffixPrefix(of: buffer, matching: Self.actionCloseMarker)
        fileContents += String(buffer.dropLast(hold.count))
        buffer = hold
        return false
    }

    private func drainInlineBody(type: String, _ events: inout [ParserEvent], atEnd: Bool) -> Bool {
        if let close = buffer.range(of: Self.actionCloseMarker) {
            inlineBuffer += String(buffer[..<close.lowerBound])
            buffer = String(buffer[close.upperBound...])
            let payload = inlineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "mcp" {
                events.append(.mcpRequest(server: mcpServer, tool: mcpTool, arguments: payload))
            } else if type == "web-fetch" {
                events.append(.webRequest(kind: .fetch, query: payload))
            } else if type == "web-search" {
                events.append(.webRequest(kind: .search, query: payload))
            } else if type == "todo" {
                events.append(.todoUpdate(TodoItem.parse(payload)))
            } else if let action = makeInlineAction(type: type, payload: payload) {
                events.append(.inlineAction(action))
            }
            inlineBuffer = ""
            state = .inArtifact
            return true
        }
        let hold = atEnd ? "" : longestSuffixPrefix(of: buffer, matching: Self.actionCloseMarker)
        inlineBuffer += String(buffer.dropLast(hold.count))
        buffer = hold
        return false
    }

    // MARK: - Helpers

    private func makeInlineAction(type: String, payload: String) -> StormbreakerAction? {
        switch type {
        case "shell": return .shell(command: payload)
        case "start": return .start(command: payload)
        case "add-dependency": return .addDependency(package: payload)
        default: return nil // "file"/"line-replace" handled separately; unknown → skip
        }
    }

    /// Parse `<<<<<<< SEARCH … ======= … >>>>>>> REPLACE` blocks into edits.
    /// Marker lines are matched by prefix so a trailing label (`SEARCH`) or
    /// whitespace is tolerated; everything else is verbatim content.
    static func parseLineEdits(_ body: String) -> [LineEdit] {
        enum Section { case none, search, replace }
        var edits: [LineEdit] = []
        var section: Section = .none
        var search: [String] = []
        var replace: [String] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<<<<<<<") {
                section = .search; search = []; replace = []
            } else if trimmed.hasPrefix("=======") && section == .search {
                section = .replace
            } else if trimmed.hasPrefix(">>>>>>>") && section == .replace {
                edits.append(LineEdit(search: search.joined(separator: "\n"),
                                      replace: replace.joined(separator: "\n")))
                section = .none
            } else {
                switch section {
                case .search: search.append(line)
                case .replace: replace.append(line)
                case .none: break
                }
            }
        }
        return edits
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        guard let start = tag.range(of: "\(name)=\"") else { return nil }
        let rest = tag[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Trim one leading and one trailing newline so a file body laid out on its
    /// own lines doesn't accrue blank edges.
    private func trimEdges(_ text: String) -> String {
        var out = text
        if out.hasPrefix("\r\n") { out.removeFirst(2) } else if out.hasPrefix("\n") { out.removeFirst() }
        if out.hasSuffix("\r\n") { out.removeLast(2) } else if out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// Defensively strip a wrapping markdown code fence (```` ```tsx `` … `` ``` ````)
    /// that local models often add despite being told not to — it would otherwise
    /// be written verbatim into the file and break the TypeScript compile.
    private func stripCodeFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return text }
        lines.removeFirst()
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Longest suffix of `buffer` that is a (proper) prefix of any needle — the
    /// fragment to hold back so a delimiter split across chunks isn't missed.
    private func longestSuffixPrefix(of buffer: String, matching needles: String...) -> String {
        var best = ""
        for needle in needles {
            let maxLen = min(buffer.count, needle.count - 1)
            var k = maxLen
            while k > 0 {
                let suffix = String(buffer.suffix(k))
                if needle.hasPrefix(suffix) {
                    if k > best.count { best = suffix }
                    break
                }
                k -= 1
            }
        }
        return best
    }
}
