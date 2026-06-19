import Foundation
#if canImport(Darwin)
import Darwin
#endif

// ─────────────────────────────────────────────────────────────────────────────
// Terminal lifecycle for the full-screen TUI (Part 3, phase 1).
//
// Owns raw mode + the alternate screen buffer. The one hard requirement is that
// the terminal is ALWAYS restored — on a clean exit, a thrown error, Ctrl-C /
// SIGTERM, or even a crash. A C signal handler can't capture context, so the
// restore state lives in file-scope vars reachable from the handler, `atexit`,
// and `defer`. `tuiRestore()` calls only write(2) + tcsetattr — both
// async-signal-safe — and is harmless to run more than once.
// ─────────────────────────────────────────────────────────────────────────────

// Reached from a C signal handler, where isolation can't apply — guarded by the
// `tuiEntered` flag + the fact that only write(2)/tcsetattr run from the handler.
private nonisolated(unsafe) var tuiSavedTermios = termios()
private nonisolated(unsafe) var tuiSavedValid = false
private nonisolated(unsafe) var tuiEntered = false

/// Raw write(2) of a static ANSI string — safe to call from a signal handler
/// (no allocation, no Swift runtime).
@inline(__always)
private func rawWrite(_ s: StaticString) {
    s.withUTF8Buffer { buf in _ = write(STDOUT_FILENO, buf.baseAddress, buf.count) }
}

/// Idempotent + async-signal-safe. Leaves the alt screen LAST so the user's
/// pre-TUI scrollback stays intact.
func tuiRestore() {
    guard tuiEntered else { return }
    tuiEntered = false
    rawWrite("\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l") // bracketed paste off, show cursor, leave alt screen
    if tuiSavedValid { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &tuiSavedTermios) }
}

/// C-callable signal handler: restore the terminal, then exit (terminating
/// signals) or re-raise the default disposition (crash signals) so we still core.
private func tuiHandleSignal(_ sig: Int32) {
    tuiRestore()
    switch sig {
    case SIGINT:  _exit(130)
    case SIGTERM: _exit(143)
    default:      signal(sig, SIG_DFL); raise(sig)   // SEGV/ILL/BUS/ABRT → crash for real
    }
}

private func tuiAtExit() { tuiRestore() }

enum TUIError: Error, CustomStringConvertible {
    case notATTY
    case termios(Int32)
    var description: String {
        switch self {
        case .notATTY:        return "ikke en TTY — kør storm i en rigtig terminal"
        case .termios(let e): return "kunne ikke sætte terminal-tilstand (errno \(e))"
        }
    }
}

/// One terminal session. `enter()` flips to raw + alt-screen and arms every
/// teardown path; `restore()` (also auto-called via defer/atexit/signals) flips back.
final class Terminal {
    private(set) var rows = 24
    private(set) var cols = 80

    func enter() throws {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { throw TUIError.notATTY }
        var raw = termios()
        if tcgetattr(STDIN_FILENO, &raw) != 0 { throw TUIError.termios(errno) }
        tuiSavedTermios = raw
        tuiSavedValid = true
        cfmakeraw(&raw)                              // no echo/canonical/signals; sets VMIN=1,VTIME=0 on Darwin
        if tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0 { throw TUIError.termios(errno) }
        rawWrite("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J\u{1B}[H\u{1B}[?2004h")   // alt screen · hide cursor · clear · home · bracketed paste on
        tuiEntered = true
        installSignalHandlers()
        atexit(tuiAtExit)
        updateSize()
    }

    func restore() { tuiRestore() }

    /// Re-read the window size (call on launch + on SIGWINCH).
    @discardableResult
    func updateSize() -> (rows: Int, cols: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_row > 0, ws.ws_col > 0 {
            rows = Int(ws.ws_row)
            cols = Int(ws.ws_col)
        }
        return (rows, cols)
    }

    private func installSignalHandlers() {
        // BSD `signal()` keeps the handler installed across firings — fine, since we
        // _exit or re-raise immediately. Avoids the sigaction struct/func name clash.
        for sig in [SIGINT, SIGTERM, SIGSEGV, SIGILL, SIGBUS, SIGABRT] {
            _ = signal(sig, tuiHandleSignal)
        }
    }
}
