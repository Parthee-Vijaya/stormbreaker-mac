// ─────────────────────────────────────────────────────────────────────────────
// Layout (Part 3, phase 3) — a flexbox-lite split solver + the fixed Forge screen
// skeleton. Pure + deterministic; recomputed only on resize.
// ─────────────────────────────────────────────────────────────────────────────

/// How a slice claims space along an axis.
public enum Constraint: Sendable, Equatable {
    case fixed(Int)      // exactly N cells
    case min(Int)        // at least N, grows with weight 1
    case ratio(Int)      // a weighted share of the leftover
    public static var flex: Constraint { .ratio(1) }

    var minSize: Int { switch self { case .fixed(let n): return max(0, n); case .min(let n): return max(0, n); case .ratio: return 0 } }
    var weight: Int { switch self { case .fixed: return 0; case .min: return 1; case .ratio(let w): return max(0, w) } }
}

public enum LayoutAxis: Sendable { case horizontal, vertical }

/// Slice `area` along `axis` into one rect per constraint. Fixed/min reserve their
/// minimum first; the leftover is distributed across weights (ratio + min). On a
/// terminal too small to honor the minimums, later slices shrink toward zero
/// (never negative).
public func splitRects(_ area: Rect, _ axis: LayoutAxis, _ constraints: [Constraint]) -> [Rect] {
    guard !constraints.isEmpty else { return [] }
    let total = axis == .vertical ? area.h : area.w
    let base = constraints.reduce(0) { $0 + $1.minSize }
    let totalWeight = constraints.reduce(0) { $0 + $1.weight }
    var leftover = max(0, total - base)

    // Size each slice: its minimum + a weighted slice of the leftover.
    var sizes = constraints.map { $0.minSize }
    if totalWeight > 0 {
        var distributed = 0
        let flexIndices = constraints.indices.filter { constraints[$0].weight > 0 }
        for (n, i) in flexIndices.enumerated() {
            let share: Int
            if n == flexIndices.count - 1 {
                share = leftover - distributed                  // last flex absorbs the rounding remainder
            } else {
                share = (leftover * constraints[i].weight) / totalWeight
            }
            sizes[i] += share
            distributed += share
        }
    }

    // If we overflowed the available space (tiny terminal), clamp cumulatively.
    var rects: [Rect] = []
    var cursor = axis == .vertical ? area.y : area.x
    let limit = (axis == .vertical ? area.y + total : area.x + total)
    for s in sizes {
        let start = min(cursor, limit)
        let size = max(0, min(s, limit - start))
        rects.append(axis == .vertical
            ? Rect(x: area.x, y: start, w: area.w, h: size)
            : Rect(x: start, y: area.y, w: size, h: area.h))
        cursor = start + size
    }
    _ = leftover                                                // (read above; silence unused on the no-weight path)
    return rects
}

/// The fixed Forge screen skeleton: a 1-row header, a body split into a scrollable
/// transcript pane and a toggleable side pane, a 1-row status bar, and a growing
/// input line. The slash-menu overlay anchors just above the input.
public struct ForgeLayout: Sendable, Equatable {
    public var header: Rect
    public var transcript: Rect
    public var side: Rect          // empty when collapsed
    public var status: Rect
    public var input: Rect
    public var slashAnchor: Rect   // where a slash-menu popover is drawn (above input)

    /// Collapse the side pane below this width — a narrow terminal gives the
    /// transcript everything.
    public static let minWidthForSide = 60

    public static func compute(_ size: Size,
                               inputHeight: Int = 1,
                               transcriptWeight: Int = 3,
                               sideWeight: Int = 2,
                               showSide: Bool = true) -> ForgeLayout {
        let full = Rect(x: 0, y: 0, w: size.cols, h: size.rows)
        let rows = splitRects(full, .vertical, [
            .fixed(1),                 // header
            .flex,                     // body
            .fixed(1),                 // status
            .fixed(max(1, inputHeight)) // input
        ])
        let header = rows[0], body = rows[1], status = rows[2], input = rows[3]

        let wantSide = showSide && size.cols >= minWidthForSide
        let (transcript, side): (Rect, Rect)
        if wantSide {
            let cols = splitRects(body, .horizontal, [.ratio(transcriptWeight), .ratio(sideWeight)])
            (transcript, side) = (cols[0], cols[1])
        } else {
            (transcript, side) = (body, Rect(x: body.maxX, y: body.y, w: 0, h: body.h))
        }
        // Slash popover: up to 8 rows tall, sitting just above the input line.
        let popH = min(8, max(1, body.h - 1))
        let slashAnchor = Rect(x: transcript.x, y: max(body.y, input.y - popH), w: transcript.w, h: popH)
        return ForgeLayout(header: header, transcript: transcript, side: side,
                           status: status, input: input, slashAnchor: slashAnchor)
    }
}
