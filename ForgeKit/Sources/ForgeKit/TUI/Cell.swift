// ─────────────────────────────────────────────────────────────────────────────
// TUI render primitives (Part 3, phase 2) — pure + deterministic, no terminal I/O.
// Lives in ForgeKit so it's unit-testable in CI without a TTY and reusable by any
// tool. The terminal-bound layer (raw mode, stdin, the event loop) lives in the
// `forge` target.
// ─────────────────────────────────────────────────────────────────────────────

/// A 24-bit color, or "use the terminal's default" (so themes can leave fg/bg unset).
public struct TermColor: Sendable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var isDefault: Bool

    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b; self.isDefault = false }
    private init(defaulted: Bool) { r = 0; g = 0; b = 0; isDefault = defaulted }

    /// The terminal's own foreground/background (SGR 39/49).
    public static let `default` = TermColor(defaulted: true)

    public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> TermColor { TermColor(r: r, g: g, b: b) }

    /// 0xRRGGBB → TermColor. Mirrors the GUI palette's hex literals.
    public static func hex(_ v: UInt32) -> TermColor {
        TermColor(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }
}

/// Foreground/background + attributes for one cell or run.
public struct Style: Sendable, Equatable {
    public var fg: TermColor
    public var bg: TermColor
    public var bold: Bool
    public var dim: Bool
    public var underline: Bool
    public var reverse: Bool

    public init(fg: TermColor = .default, bg: TermColor = .default,
                bold: Bool = false, dim: Bool = false, underline: Bool = false, reverse: Bool = false) {
        self.fg = fg; self.bg = bg; self.bold = bold; self.dim = dim
        self.underline = underline; self.reverse = reverse
    }

    public static let `default` = Style()
}

/// One screen cell: a single user-perceived character + its style + display width.
/// `width` is 1 (normal), 2 (the lead of a wide glyph), or 0 (the continuation
/// slot a wide glyph occupies — never emitted, just reserves the column).
public struct Cell: Sendable, Equatable {
    public var grapheme: Character
    public var style: Style
    public var width: Int8

    public init(_ grapheme: Character = " ", _ style: Style = .default, width: Int8 = 1) {
        self.grapheme = grapheme; self.style = style; self.width = width
    }

    /// An empty default cell.
    public static let blank = Cell(" ", .default, width: 1)
    /// The continuation slot reserved by a wide glyph to its left.
    public static func continuation(_ style: Style = .default) -> Cell { Cell(" ", style, width: 0) }
}
