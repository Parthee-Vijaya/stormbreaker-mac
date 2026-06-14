import Foundation

/// Turns raw dev-server log lines + browser runtime issues into a deduplicated
/// `ErrorReport`. Pure and `Sendable`.
///
/// Goals (vs. naive substring matching):
/// - parse structured locations (`file:line:col`, `(line,col)`, `TSxxxx`) so
///   the same error reported by tsc *and* the Vite overlay dedups to one item;
/// - filter dev-server noise (Vite connection/HMR/ready banners, Rollup
///   warnings) and non-fatal React dev `Warning:` console output, which would
///   otherwise keep the self-correction loop from ever converging.
public struct ErrorClassifier: Sendable {
    public init() {}

    public func report(logs: [LogLine], runtime: [RuntimeIssue]) -> ErrorReport {
        var items: [ErrorReport.Item] = []
        var seen = Set<String>()

        for line in logs {
            guard let item = classifyBuildLine(line.text) else { continue }
            if seen.insert(item.dedupKey).inserted { items.append(item) }
        }
        for issue in runtime {
            guard let item = classifyRuntime(issue) else { continue }
            if seen.insert(item.dedupKey).inserted { items.append(item) }
        }
        return ErrorReport(items: items)
    }

    // MARK: - Build lines (tsc / Vite / esbuild)

    func classifyBuildLine(_ raw: String) -> ErrorReport.Item? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isNoise(text), looksLikeError(text) else { return nil }

        let location = Self.fileLocation.firstMatch(in: text)
        let code = Self.tsCode.firstMatch(in: text)?.text(at: 1, in: text)

        return ErrorReport.Item(
            source: .build,
            message: text,
            file: location?.text(at: 1, in: text),
            line: location.flatMap { Int($0.text(at: 2, in: text) ?? "") },
            code: code)
    }

    /// Dev-server output that is informational, not an error.
    private func isNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("0 error") || lower.contains("no error") || lower.contains("found 0 error") {
            return true
        }
        let noise = [
            "[vite] connecting", "[vite] connected", "[vite] hot updated",
            "[vite] hmr", "[vite] page reload", "[vite] invalidate",
            "server connection lost", "polling for restart",
            "ready in", "use --host", "➜", "vite v",
            "(!) ", "sourcemap", "[deprecation", "npm warn", "deprecated",
        ]
        return noise.contains { lower.contains($0) }
    }

    /// Whitelist of genuine build-error markers.
    private func looksLikeError(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "error", "failed to compile", "cannot find", "is not defined",
            "unexpected token", "syntaxerror", "referenceerror", "typeerror",
            "pre-transform error", "[plugin:", "✘", "x [error]",
            "internal server error", "failed to resolve import", "could not resolve",
        ]
        return markers.contains { lower.contains($0) }
    }

    // MARK: - Runtime (browser bridge)

    func classifyRuntime(_ issue: RuntimeIssue) -> ErrorReport.Item? {
        // onerror / unhandledRejection are always real crashes. console.error is
        // kept *except* React's non-fatal dev warnings and tooling hints.
        if issue.kind == .consoleError, isRuntimeNoise(issue.message) { return nil }
        return ErrorReport.Item(
            source: .runtime,
            message: issue.displayMessage,
            file: issue.source,
            line: issue.line,
            code: nil)
    }

    private func isRuntimeNoise(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if trimmed.hasPrefix("Warning:") { return true }          // React dev warnings
        let hints = [
            "download the react devtools", "react devtools",
            "[vite] connecting", "[vite] connected", "[hmr]",
        ]
        return hints.contains { lower.contains($0) }
    }

    // MARK: - Patterns

    /// `path/to/file.tsx:12:5` or `path/to/file.tsx(12,5)` → (file, line, col).
    /// The separators use alternation, not char classes: `[:(]…[,:]` reads as a
    /// malformed POSIX class to ICU and fails to compile.
    static let fileLocation = Regex(
        #"([A-Za-z0-9._/@\-]+\.(?:tsx?|jsx?|mjs|cjs|css|scss|json|vue|svelte))(?::|\()(\d+)(?:,|:)(\d+)"#)
    /// TypeScript diagnostic code, e.g. `TS2304`.
    static let tsCode = Regex(#"\b(TS\d{3,5})\b"#)
}

/// Tiny `NSRegularExpression` wrapper so the classifier stays `Sendable` and the
/// call sites read cleanly.
struct Regex: @unchecked Sendable {
    private let regex: NSRegularExpression?
    init(_ pattern: String) {
        regex = try? NSRegularExpression(pattern: pattern)
    }
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

extension NSTextCheckingResult {
    /// Captured group `index` as a substring of `text`, or nil if not matched.
    func text(at index: Int, in text: String) -> String? {
        guard index < numberOfRanges, let range = Range(range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
