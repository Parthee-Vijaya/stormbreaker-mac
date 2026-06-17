// ─────────────────────────────────────────────────────────────────────────────
// Input decoding (Part 3, phase 4) — pure byte→Key state machine, no I/O.
// The terminal-bound reader (blocking read(2) off the main actor) lives in the
// `forge` target; this part is fully unit-testable with byte fixtures.
// ─────────────────────────────────────────────────────────────────────────────

/// A decoded keypress.
public enum Key: Sendable, Equatable {
    case char(Character)          // a printable grapheme
    case enter, tab, backspace, escape, delete
    case up, down, left, right, home, end, pageUp, pageDown
    case ctrl(Character)          // Ctrl-<letter>, e.g. .ctrl("c")
    case alt(Character)           // ESC-prefixed (Meta), e.g. .alt("b")
    case paste(String)            // a bracketed-paste payload — one event, not N chars
    case unknown([UInt8])         // an unrecognized escape sequence
}

/// Incremental decoder: feed it raw bytes (which may split a rune or sequence across
/// reads), get back complete `Key`s. A lone trailing ESC is held until more bytes
/// arrive or `flush()` is called (the reader does a short grace-poll then flushes).
public struct KeyDecoder {
    private var pending: [UInt8] = []
    public init() {}

    /// True while a bare ESC (or an incomplete sequence) is buffered.
    public var isHoldingEscape: Bool { pending.first == 0x1B }

    public mutating func feed<S: Sequence>(_ bytes: S) -> [Key] where S.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var keys: [Key] = []
        while let (key, consumed) = parseFront() {
            keys.append(key)
            pending.removeFirst(consumed)
        }
        return keys
    }

    /// Emit a held bare ESC as `.escape` (called on input-idle). Leaves a genuinely
    /// incomplete UTF-8/sequence buffered for the next read.
    public mutating func flush() -> [Key] {
        if pending == [0x1B] { pending.removeAll(); return [.escape] }
        return []
    }

    // MARK: - Front parsing  (returns nil when more bytes are needed)

    private func parseFront() -> (Key, Int)? {
        guard let b0 = pending.first else { return nil }
        switch b0 {
        case 0x1B: return parseEscape()
        case 0x09: return (.tab, 1)
        case 0x0D, 0x0A: return (.enter, 1)
        case 0x08, 0x7F: return (.backspace, 1)
        case 0x00..<0x20: return (.ctrl(Character(UnicodeScalar(0x60 + b0))), 1)   // ^A..^Z etc.
        default: return parseUTF8()
        }
    }

    private func parseEscape() -> (Key, Int)? {
        guard pending.count >= 2 else { return nil }            // hold a lone ESC
        switch pending[1] {
        case 0x5B: return parseCSI()                            // '['
        case 0x4F: return parseSS3()                            // 'O'
        case 0x1B: return (.escape, 1)                          // ESC ESC → one escape, keep rest
        case 0x20..<0x7F: return (.alt(Character(UnicodeScalar(pending[1]))), 2)
        default: return (.escape, 1)
        }
    }

    private func parseCSI() -> (Key, Int)? {
        var i = 2
        while i < pending.count, !(pending[i] >= 0x40 && pending[i] <= 0x7E) { i += 1 }
        guard i < pending.count else { return nil }             // final byte not arrived
        let final = pending[i]
        let params = String(decoding: pending[2..<i], as: UTF8.self)
        if final == 0x7E {                                      // '~' — numbered keys
            switch params {
            case "200": return parsePaste(contentStart: i + 1)
            case "1", "7": return (.home, i + 1)
            case "3": return (.delete, i + 1)
            case "4", "8": return (.end, i + 1)
            case "5": return (.pageUp, i + 1)
            case "6": return (.pageDown, i + 1)
            default: return (.unknown(Array(pending[0...i])), i + 1)
            }
        }
        switch final {
        case 0x41: return (.up, i + 1)
        case 0x42: return (.down, i + 1)
        case 0x43: return (.right, i + 1)
        case 0x44: return (.left, i + 1)
        case 0x48: return (.home, i + 1)
        case 0x46: return (.end, i + 1)
        default: return (.unknown(Array(pending[0...i])), i + 1)
        }
    }

    private func parseSS3() -> (Key, Int)? {
        guard pending.count >= 3 else { return nil }
        switch pending[2] {
        case 0x41: return (.up, 3)
        case 0x42: return (.down, 3)
        case 0x43: return (.right, 3)
        case 0x44: return (.left, 3)
        case 0x48: return (.home, 3)
        case 0x46: return (.end, 3)
        default: return (.unknown(Array(pending[0...2])), 3)
        }
    }

    /// pending begins with `ESC [ 200 ~`; collect until the `ESC [ 201 ~` terminator.
    private func parsePaste(contentStart start: Int) -> (Key, Int)? {
        let term: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC[201~
        var i = start
        while i + term.count <= pending.count {
            if Array(pending[i..<i + term.count]) == term {
                return (.paste(String(decoding: pending[start..<i], as: UTF8.self)), i + term.count)
            }
            i += 1
        }
        return nil                                              // terminator not yet arrived
    }

    private func parseUTF8() -> (Key, Int)? {
        let b0 = pending[0]
        let len: Int
        if b0 < 0x80 { len = 1 }
        else if b0 & 0xE0 == 0xC0 { len = 2 }
        else if b0 & 0xF0 == 0xE0 { len = 3 }
        else if b0 & 0xF8 == 0xF0 { len = 4 }
        else { return (.unknown([b0]), 1) }                     // invalid lead byte
        guard pending.count >= len else { return nil }          // multibyte split across reads
        let bytes = Array(pending[0..<len])
        guard let ch = String(decoding: bytes, as: UTF8.self).first else {
            return (.unknown(bytes), len)
        }
        return (.char(ch), len)
    }
}
