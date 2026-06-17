import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SyntaxRules (Part 3, phase 8) — the TS/JSX highlight patterns, in one place.
// The GUI (CodePane.SyntaxHighlighter, NSColor) and the CLI TUI (ANSIColorizer,
// terminal Style) both consume these, so the patterns can't drift. This type owns
// ONLY the patterns + a deterministic per-character classifier — no colors, no
// platform types — so it's testable in ForgeKit.
// ─────────────────────────────────────────────────────────────────────────────

public enum SyntaxRules {
    public enum Token: Sendable, Equatable { case keyword, type, number, string, comment }

    public static let keywordPattern =
        #"\b(const|let|var|function|return|if|else|for|while|import|export|from|class|extends|implements|new|async|await|try|catch|finally|throw|typeof|instanceof|in|of|switch|case|break|continue|default|do|yield|interface|type|enum|public|private|protected|static|readonly|get|set|null|undefined|true|false|this|super|void|as|namespace|declare|abstract|override)\b"#
    public static let typePattern    = #"\b[A-Z][A-Za-z0-9_]*\b"#
    public static let numberPattern  = #"\b\d+(?:\.\d+)?\b"#
    public static let stringPattern  = #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
    public static let commentPattern = #"//[^\n]*|/\*[\s\S]*?\*/"#

    /// Compiled regexes in precedence order — earlier matches are overwritten by
    /// later ones, so a keyword inside a string loses to the string, and everything
    /// loses to a comment (matches the GUI's ordering).
    public static let ordered: [(Token, NSRegularExpression)] = [
        (.type, re(typePattern)), (.keyword, re(keywordPattern)),
        (.number, re(numberPattern)), (.string, re(stringPattern)), (.comment, re(commentPattern)),
    ]

    private static func re(_ p: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: p)) ?? NSRegularExpression()
    }

    /// Classify each character of one line into a token (or nil = plain). Last writer
    /// wins by `ordered` precedence. Per-line (block comments / template literals that
    /// span lines are only highlighted on the lines that match) — fine for a live view.
    public static func classify(_ line: String) -> [Token?] {
        var map = [Token?](repeating: nil, count: line.count)
        guard !line.isEmpty else { return map }
        let range = NSRange(line.startIndex..., in: line)
        for (token, regex) in ordered {
            for match in regex.matches(in: line, range: range) {
                guard let r = Range(match.range, in: line) else { continue }
                let lo = line.distance(from: line.startIndex, to: r.lowerBound)
                let hi = line.distance(from: line.startIndex, to: r.upperBound)
                for i in lo..<hi where i >= 0 && i < map.count { map[i] = token }
            }
        }
        return map
    }
}
