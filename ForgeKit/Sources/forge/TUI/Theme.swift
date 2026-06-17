import ForgeKit

// ─────────────────────────────────────────────────────────────────────────────
// ANSITheme (Part 3, phase 7) — one palette read by the App chrome, the syntax
// colorizer (P8), and the diff renderer (P9). `/theme` (P12) switches it. Colors
// mirror the GUI palettes (CodePane SyntaxHighlighter + DiffView). `.mono` uses
// the terminal defaults — the low-color / accessibility fallback.
// ─────────────────────────────────────────────────────────────────────────────

struct ANSITheme: Sendable, Equatable {
    var name: String
    // Chrome
    var accent: Color
    var error: Color
    var ok: Color
    var warn: Color
    // Syntax (TS/JSX)
    var keyword: Color
    var type: Color
    var number: Color
    var string: Color
    var comment: Color
    // Diff
    var diffAdd: Color
    var diffDel: Color
    var diffHunk: Color
    var diffMeta: Color

    // Convenience styles
    var accentStyle: Style { Style(fg: accent) }
    var accentBold: Style { Style(fg: accent, bold: true) }
    var dimStyle: Style { Style(dim: true) }
    var errorStyle: Style { Style(fg: error) }
    var okStyle: Style { Style(fg: ok) }
    var warnStyle: Style { Style(fg: warn, bold: true) }

    static let midnight = ANSITheme(
        name: "Midnat",
        accent: .hex(0x9B87F5), error: .hex(0xE05252), ok: .hex(0x57B85A), warn: .hex(0xE0A030),
        keyword: .hex(0xC792EA), type: .hex(0x82AAFF), number: .hex(0xF78C6C),
        string: .hex(0xC3E88D), comment: .hex(0x6B7180),
        diffAdd: .hex(0x57B85A), diffDel: .hex(0xE05252), diffHunk: .hex(0x82AAFF), diffMeta: .hex(0x6B7180))

    static let light = ANSITheme(
        name: "Lys",
        accent: .hex(0x6D28D9), error: .hex(0xC2181B), ok: .hex(0x15803D), warn: .hex(0xB45309),
        keyword: .hex(0x7C3AED), type: .hex(0x2563EB), number: .hex(0xC2410C),
        string: .hex(0x16A34A), comment: .hex(0x9AA0AE),
        diffAdd: .hex(0x15803D), diffDel: .hex(0xC2181B), diffHunk: .hex(0x2563EB), diffMeta: .hex(0x9AA0AE))

    static let mono = ANSITheme(
        name: "Mono",
        accent: .default, error: .default, ok: .default, warn: .default,
        keyword: .default, type: .default, number: .default, string: .default, comment: .default,
        diffAdd: .default, diffDel: .default, diffHunk: .default, diffMeta: .default)

    static let all: [ANSITheme] = [.midnight, .light, .mono]
    static func named(_ n: String) -> ANSITheme? { all.first { $0.name.lowercased() == n.lowercased() } }
}
