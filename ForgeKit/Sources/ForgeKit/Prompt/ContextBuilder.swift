import Foundation

/// Builds the `<project_context>` body for a model turn within a token budget,
/// so large projects don't silently blow past `num_ctx` (Ollama truncates
/// quietly — the failure mode we most want to avoid).
///
/// Strategy: always include a compact file map, then inline file *contents* in
/// priority order (recently-touched files first, then entry points, then the
/// rest of `src/`) until the budget runs out. The last file is head-truncated
/// rather than dropped whole if it doesn't fit.
public struct ContextBuilder: Sendable {
    /// Approximate token budget for inlined file *contents* (≈ chars / 4).
    public var tokenBudget: Int
    /// Max entries listed in the file map before collapsing to "… and N more".
    public var maxListedFiles: Int

    public init(tokenBudget: Int = 8000, maxListedFiles: Int = 100) {
        self.tokenBudget = tokenBudget
        self.maxListedFiles = maxListedFiles
    }

    public func build(
        files: [String],
        touched: [String],
        read: (String) async -> String?
    ) async -> String? {
        guard !files.isEmpty else { return nil }

        var out = "Project files:\n" + Self.fileList(files, max: maxListedFiles)

        var budget = tokenBudget
        var includedPaths = Set<String>()
        for path in Self.prioritize(files: files, touched: touched) {
            guard !includedPaths.contains(path), Self.isSource(path) else { continue }
            guard let content = await read(path) else { continue }
            let cost = Self.estimateTokens(content)
            let body: String
            if cost <= budget {
                body = content
                budget -= cost
            } else if includedPaths.isEmpty {
                // Even the top-priority file is bigger than the whole budget —
                // include a head slice so the model still sees the entry file.
                body = Self.truncate(content, toTokens: budget)
                budget = 0
            } else {
                continue
            }
            includedPaths.insert(path)
            out += "\n\n\(path):\n```\(Self.lang(path))\n\(body)\n```"
            if budget <= 0 { break }
        }
        return out
    }

    // MARK: - Helpers (static + internal for tests)

    static func estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }

    /// Priority: recently-touched (most recent first) → entry points → the rest
    /// of `src/`, alphabetical. Deduplicated, only existing files.
    static func prioritize(files: [String], touched: [String]) -> [String] {
        let known = Set(files)
        var ordered: [String] = []
        var seen = Set<String>()
        func push(_ p: String) {
            guard known.contains(p), seen.insert(p).inserted else { return }
            ordered.append(p)
        }
        for p in touched { push(p) }
        for p in ["src/App.tsx", "src/App.jsx", "src/main.tsx", "src/index.css"] { push(p) }
        for p in files.filter({ $0.hasPrefix("src/") }).sorted(by: depthThenName) { push(p) }
        return ordered
    }

    /// Shallower paths first, then alphabetical — entry-ish files float up.
    static func depthThenName(_ a: String, _ b: String) -> Bool {
        let da = a.filter { $0 == "/" }.count, db = b.filter { $0 == "/" }.count
        return da != db ? da < db : a < b
    }

    static func fileList(_ files: [String], max: Int) -> String {
        if files.count <= max {
            return files.map { "- \($0)" }.joined(separator: "\n")
        }
        let head = files.prefix(max).map { "- \($0)" }.joined(separator: "\n")
        return head + "\n- … and \(files.count - max) more files"
    }

    static func isSource(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["tsx", "ts", "jsx", "js", "css", "scss"].contains(ext)
    }

    static func lang(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "tsx": "tsx"
        case "ts": "ts"
        case "jsx": "jsx"
        case "js": "js"
        case "css", "scss": "css"
        default: "text"
        }
    }

    static func truncate(_ text: String, toTokens tokens: Int) -> String {
        let maxChars = max(0, tokens * 4)
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "\n// … (truncated for context budget)"
    }
}
