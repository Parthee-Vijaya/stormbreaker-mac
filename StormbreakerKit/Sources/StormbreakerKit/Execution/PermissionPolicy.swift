import Foundation

/// A side-effectful action the user may want to approve before it runs. Only the
/// three "escape hatches" are gated — file writes are already checkpointed,
/// diffable and restorable, and `start` (npm run dev) is inert.
public enum PermissionRequest: Sendable, Equatable {
    case shell(command: String)
    case addDependencies([String])
    case mcp(server: String, tool: String)

    /// A human-readable one-line description, for prompts + deny-feedback.
    public var label: String {
        switch self {
        case .shell(let command):
            return "køre kommandoen: \(command)"
        case .addDependencies(let packages):
            return "installere pakke(r): \(packages.joined(separator: ", "))"
        case .mcp(let server, let tool):
            return "kalde det eksterne værktøj: \(server)/\(tool)"
        }
    }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow            // run this once
    case allowForSession  // run + don't ask again this session (the gate remembers)
    case deny             // skip it
}

/// Approves or denies side-effectful actions before they run. The gate owns any
/// "remember for this session" behaviour; callers treat `allow`/`allowForSession`
/// the same (proceed) and `deny` as skip.
public protocol PermissionGate: Sendable {
    func decide(_ request: PermissionRequest) async -> PermissionDecision
}

/// Per-command triage for shell actions (opencode borrow). Instead of asking the
/// user about EVERY shell command, classify it first:
/// - `.allow` — known-safe dev tooling (npm run, npx tsc, git status, ls…): run
///   without a prompt.
/// - `.deny` — catastrophic or supply-chain patterns (rm -rf /, sudo, pipe-to-shell,
///   fork bomb, disk wipe): refuse outright, even under an allow-all gate.
/// - `.ask` — everything else (unknown binaries, installing named packages, git push,
///   non-root rm…): fall through to the permission gate as before.
///
/// The point is fewer prompts on the safe 90% AND a hard floor under the dangerous
/// few. A chain is `.allow` only if EVERY segment is safe; any catastrophic segment
/// makes the whole command `.deny`; otherwise `.ask`.
public enum ShellVerdict: Sendable, Equatable { case allow, ask, deny }

public enum ShellRules {
    public static func classify(_ command: String) -> ShellVerdict {
        let whole = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if whole.isEmpty { return .allow }
        // Operator-dependent dangers that wouldn't survive segment-splitting.
        if pipesToShell(whole) || isForkBomb(whole) || redirectsToDisk(whole) { return .deny }
        // Per-segment: most-restrictive wins (deny > ask > allow).
        var verdict: ShellVerdict = .allow
        for segment in splitSegments(whole) {
            switch classifySegment(segment) {
            case .deny: return .deny
            case .ask: verdict = .ask
            case .allow: continue
            }
        }
        return verdict
    }

    // MARK: - Known-safe binaries (no arguments make them dangerous)

    private static let safeBins: Set<String> = [
        "npx", "node", "deno", "tsc", "vite", "eslint", "prettier", "biome",
        "jest", "vitest", "playwright", "tailwindcss", "tsx", "ts-node",
        "ls", "cat", "pwd", "echo", "mkdir", "touch", "which", "head", "tail",
        "wc", "grep", "rg", "find", "cd", "true", "clear", "env", "date", "cp",
    ]

    private static let safeGitSubcommands: Set<String> = [
        "status", "add", "commit", "diff", "log", "branch", "show", "stash",
        "fetch", "checkout", "switch", "restore", "init", "config", "remote",
        "rev-parse", "ls-files", "tag", "describe",
    ]

    // MARK: - Per-segment classification

    private static func classifySegment(_ segment: String) -> ShellVerdict {
        let seg = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if seg.isEmpty { return .allow }
        // Never auto-run anything that hides a sub-command behind substitution.
        if seg.contains("$(") || seg.contains("`") || seg.contains("${") { return .ask }

        var tokens = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Strip leading `FOO=bar` env-var assignments.
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            tokens.removeFirst()
        }
        guard let head = tokens.first else { return .allow }
        let args = Array(tokens.dropFirst())
        let bin = (head as NSString).lastPathComponent

        switch bin {
        case "sudo", "su", "doas":            return .deny   // privilege escalation
        case let b where b.hasPrefix("mkfs"): return .deny   // filesystem format
        case "dd":
            return args.contains { $0.hasPrefix("of=/dev/") } ? .deny : .ask
        case "chmod":
            return chmodIsCatastrophic(args) ? .deny : .ask
        case "rm":
            return rmIsCatastrophic(args) ? .deny : .ask
        case "npm", "pnpm", "yarn", "bun":
            return installsNamedPackage(args) ? .ask : .allow
        case "git":
            let sub = args.first { !$0.hasPrefix("-") }
            return (sub == nil || safeGitSubcommands.contains(sub!)) ? .allow : .ask
        default:
            return safeBins.contains(bin) ? .allow : .ask
        }
    }

    /// `npm install left-pad`, `yarn add x`, `pnpm i foo` install NEW packages — a
    /// supply-chain surface, so ask. Bare `npm install` (lockfile restore), `npm run`,
    /// `npm test`, `npm ci` are safe.
    private static func installsNamedPackage(_ args: [String]) -> Bool {
        let nonFlags = args.filter { !$0.hasPrefix("-") }
        guard let sub = nonFlags.first else { return false }
        if sub == "add" { return true }
        if sub == "install" || sub == "i" { return nonFlags.count > 1 }  // a named pkg follows
        return false
    }

    /// rm is catastrophic only when recursive+force AND the target is the filesystem
    /// root, the home dir, or a top-level system dir. `rm -rf node_modules` / `rm -rf .`
    /// stay `.ask` (legitimate + checkpoint-recoverable).
    private static func rmIsCatastrophic(_ args: [String]) -> Bool {
        let flags = args.filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }.joined()
        let recursive = flags.contains("r") || flags.contains("R") || args.contains("--recursive")
        let force = flags.contains("f") || args.contains("--force") || args.contains("--no-preserve-root")
        guard recursive && force else { return false }
        let targets = args.filter { !$0.hasPrefix("-") }
        return targets.contains { t in
            if ["/", "~", "~/", "$HOME", "${HOME}", "/*", "~/*", "$HOME/*"].contains(t) { return true }
            // top-level system dir like /etc, /usr, /System (one path component, not /tmp or /var/folders)
            if t.hasPrefix("/"), !t.hasPrefix("/tmp"), !t.hasPrefix("/private"), !t.hasPrefix("/var/folders") {
                return t.dropFirst().split(separator: "/").count <= 1
            }
            return false
        }
    }

    private static func chmodIsCatastrophic(_ args: [String]) -> Bool {
        let has777 = args.contains { $0.contains("777") }
        let onRoot = args.contains { $0.hasPrefix("/") && $0.dropFirst().split(separator: "/").count <= 1 }
        return has777 && onRoot
    }

    // MARK: - Whole-string danger patterns

    /// `curl … | sh`, `wget … | bash`, or any `| sh`/`| bash` pipe into an interpreter.
    private static func pipesToShell(_ s: String) -> Bool {
        s.range(of: #"\|\s*(sudo\s+)?(ba|z|k|c|tc|da)?sh\b"#, options: .regularExpression) != nil
    }

    private static func isForkBomb(_ s: String) -> Bool {
        s.replacingOccurrences(of: " ", with: "").contains(":(){:|:&};:")
    }

    /// Redirecting into a raw block device (`> /dev/sda`, `>/dev/disk0`).
    private static func redirectsToDisk(_ s: String) -> Bool {
        s.range(of: #">\s*/dev/(sd|disk|nvme|hd|rdisk)"#, options: .regularExpression) != nil
    }

    /// Split on `&&`, `||`, `;`, `|`, and newlines so each command runs through
    /// `classifySegment`. Erring toward MORE segments is safe — it can only make the
    /// verdict more conservative.
    private static func splitSegments(_ s: String) -> [String] {
        var normalized = s.replacingOccurrences(of: "&&", with: "\n")
                          .replacingOccurrences(of: "||", with: "\n")
        for ch in ["|", ";"] { normalized = normalized.replacingOccurrences(of: ch, with: "\n") }
        return normalized.split(separator: "\n").map(String.init)
    }
}
