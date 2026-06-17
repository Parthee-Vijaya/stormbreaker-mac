import Foundation

/// Assembles the message array for a model turn: system prompt + chat history +
/// the new user message (with optional project context inlined). Provider-
/// agnostic — the Anthropic adapter splits the system message out itself.
public struct MessageBuilder: Sendable {
    public init() {}

    public func build(
        systemPrompt: String,
        projectContext: String?,
        history: [ChatMessage],
        userPrompt: String,
        images: [String] = []
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: systemPrompt)]
        messages.append(contentsOf: history)

        let content: String
        if let context = projectContext, !context.isEmpty {
            content = "<project_context>\n\(context)\n</project_context>\n\n\(userPrompt)"
        } else {
            content = userPrompt
        }
        messages.append(ChatMessage(role: .user, content: content, imageDataURLs: images))
        return messages
    }

    /// A follow-up user turn returning the contents of files the model asked to
    /// read (A2b), so it can continue building with accurate context.
    public func readResultTurn(_ files: [(path: String, contents: String?)]) -> ChatMessage {
        var body = "Here are the files you requested. Continue with these in mind — do NOT request them again.\n\n"
        for file in files {
            if let contents = file.contents {
                body += "<file path=\"\(file.path)\">\n\(contents)\n</file>\n\n"
            } else {
                body += "<file path=\"\(file.path)\">(this file does not exist)</file>\n\n"
            }
        }
        return ChatMessage(role: .user, content: body)
    }

    /// Feeds external MCP tool results back so the model can continue the build.
    public func mcpResultTurn(_ results: [(server: String, tool: String, output: String)]) -> ChatMessage {
        var body = "Results of the tool(s) you called. Continue the build with these in mind — don't call them again unless needed.\n\n"
        for r in results {
            body += "<tool server=\"\(r.server)\" name=\"\(r.tool)\">\n\(r.output)\n</tool>\n\n"
        }
        return ChatMessage(role: .user, content: body)
    }

    /// Tells the model the user declined certain side-effectful actions, so it
    /// adapts instead of retrying them.
    public func deniedTurn(_ denied: [String]) -> ChatMessage {
        var body = "The user DECLINED to run the following action(s):\n"
        for action in denied { body += "- \(action)\n" }
        body += "\nDo NOT attempt them again. Continue without them — e.g. write the code so it "
            + "doesn't need that dependency or command, or proceed with what's already in place."
        return ChatMessage(role: .user, content: body)
    }

    /// A follow-up user turn that feeds back the errors for self-correction.
    /// When `files` is supplied (A11), the current contents of the failing files are
    /// inlined so the model repairs against the real code instead of guessing.
    public func errorTurn(_ report: ErrorReport, files: [(path: String, contents: String?)] = []) -> ChatMessage {
        var body = """
        The app has errors. Fix the root cause with the smallest correct edit, then re-emit the \
        affected file(s). Do not restart the dev server.

        \(report.formatted())
        """
        let present = files.filter { $0.contents != nil }
        if !present.isEmpty {
            body += "\n\nCurrent contents of the affected file(s) — edit these, don't recreate from scratch:\n\n"
            for file in present {
                body += "<file path=\"\(file.path)\">\n\(file.contents ?? "")\n</file>\n\n"
            }
        }
        return ChatMessage(role: .user, content: body)
    }
}
