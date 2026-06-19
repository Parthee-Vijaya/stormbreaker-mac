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
/// - `.allow` — known-safe dev tooling (npm run, tsc, git status, ls…): run
///   without a prompt.
/// - `.deny` — catastrophic or supply-chain patterns (rm -rf /, sudo, pipe-to-shell,
///   fork bomb, disk wipe): refuse outright, even under an allow-all gate.
/// - `.ask` — everything else (unknown binaries, code-runners like node/npx,
///   installing named packages, git push, reading secret files…): fall through to
///   the permission gate.
///
/// The point is fewer prompts on the safe 90% AND a hard floor under the dangerous
/// few. A chain is `.allow` only if EVERY segment is safe; any catastrophic segment
/// makes the whole command `.deny`; otherwise `.ask`.
///
/// Security posture (hardened 2026-06): the allowlist is deliberately SMALL and
/// holds only binaries that can't run arbitrary code or read secrets no matter the
/// arguments. Code-runners (`node`, `deno`, `npx`, `tsx`, `ts-node`, `env`) are NOT
/// auto-allowed — they're trivial RCE (`node -e …`, `npx <anything>`). File tools
/// (`cat`, `grep`, `cp`, `find`) get argument-aware handlers so reading `~/.ssh` or
/// `find -delete` is gated, while ordinary in-project use stays frictionless.
public enum ShellVerdict: Sendable, Equatable { case allow, ask, deny }

public enum ShellRules {
    public static func classify(_ command: String) -> ShellVerdict {
        classifyInternal(command, depth: 0)
    }

    private static func classifyInternal(_ command: String, depth: Int) -> ShellVerdict {
        let whole = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if whole.isEmpty { return .allow }
        // Operator-dependent dangers that wouldn't survive segment-splitting.
        if pipesToShell(whole) || isForkBomb(whole) || redirectsToDisk(whole) { return .deny }
        // Per-segment: most-restrictive wins (deny > ask > allow).
        var verdict: ShellVerdict = .allow
        for segment in splitSegments(whole) {
            switch classifySegment(segment, depth: depth) {
            case .deny: return .deny
            case .ask: verdict = .ask
            case .allow: continue
            }
        }
        // Output redirection to anywhere outside the project (or onto a secret /
        // shell-rc file) is gated independently of how safe the head binary is —
        // `echo x > ~/.zshrc` and `env > leak.txt` must not slip through just
        // because `echo`/`env` look harmless.
        if verdict == .allow, redirectsOutsideProject(whole) { verdict = .ask }
        return verdict
    }

    // MARK: - Known-safe binaries (no arguments make them dangerous)

    /// Deliberately minimal. A binary belongs here ONLY if no argument turns it into
    /// arbitrary code execution or a secret read. Code-runners and file-touching
    /// tools live in dedicated handlers below, never here.
    private static let safeBins: Set<String> = [
        "tsc", "vite", "eslint", "prettier", "biome",
        "jest", "vitest", "playwright", "tailwindcss",
        "ls", "pwd", "echo", "mkdir", "touch", "which",
        "cd", "true", "false", "clear", "date", "whoami", "hostname",
    ]

    /// Shells that run an arbitrary payload after `-c` — we must look INSIDE.
    private static let shellBins: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "ash", "fish"]

    /// File readers — safe in-project, but `cat ~/.ssh/id_rsa` is a secret leak.
    /// Allowed unless an argument points at a sensitive path.
    private static let fileReaders: Set<String> = [
        "cat", "grep", "egrep", "fgrep", "rg", "ag", "head", "tail", "wc",
        "less", "more", "od", "xxd", "strings", "nl", "tac",
    ]

    private static let safeGitSubcommands: Set<String> = [
        "status", "add", "commit", "diff", "log", "branch", "show", "stash",
        "fetch", "checkout", "switch", "restore", "init",
        "rev-parse", "ls-files", "tag", "describe",
    ]

    // MARK: - Per-segment classification

    private static func classifySegment(_ segment: String, depth: Int) -> ShellVerdict {
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

        // Recurse into wrappers that carry a real command inside them.
        if shellBins.contains(bin) { return classifyShellWrapper(seg, depth: depth) }
        if bin == "env"            { return classifyEnvWrapper(tokens, depth: depth) }
        if bin == "xargs" || bin == "nice" || bin == "nohup" || bin == "time" || bin == "timeout" {
            // These prefix another command; classify the tail conservatively.
            return depth < 4 ? classifyInternal(args.joined(separator: " "), depth: depth + 1) : .ask
        }

        switch bin {
        case "sudo", "su", "doas":            return .deny   // privilege escalation
        case let b where b.hasPrefix("mkfs"): return .deny   // filesystem format
        case "dd":
            return args.contains { $0.hasPrefix("of=/dev/") } ? .deny : .ask
        case "chmod":
            return chmodIsCatastrophic(args) ? .deny : .ask
        case "rm":
            return rmIsCatastrophic(args) ? .deny : .ask
        case "find":
            return classifyFind(args)
        case "cp":
            // `cp` was previously auto-allowed; keep ordinary in-project copies
            // frictionless but gate exfiltration (`cp ~/.aws/credentials ./public`).
            // `mv`/`rsync`/`scp`/`ln` were never auto-allowed → they fall to `.ask`.
            return touchesSensitivePath(args) ? .ask : .allow
        case let b where fileReaders.contains(b):
            return touchesSensitivePath(args) ? .ask : .allow
        case "npm", "pnpm", "yarn", "bun":
            return installsNamedPackage(args) ? .ask : .allow
        case "git":
            let sub = args.first { !$0.hasPrefix("-") }
            return (sub == nil || safeGitSubcommands.contains(sub!)) ? .allow : .ask
        default:
            return safeBins.contains(bin) ? .allow : .ask
        }
    }

    /// `sh -c '<payload>'` / `bash -c "<payload>"` — the head looks innocuous but the
    /// payload is the real command, so classify IT (recursively, depth-guarded).
    private static func classifyShellWrapper(_ seg: String, depth: Int) -> ShellVerdict {
        guard depth < 4 else { return .ask }
        // Find the `-c` flag and take everything after it as the payload.
        guard let r = seg.range(of: #"(?:^|\s)-c(?:\s|$)"#, options: .regularExpression) else {
            return .ask   // interactive shell, or a script-file invocation — gate it
        }
        var payload = String(seg[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        payload = stripWrappingQuotes(payload)
        if payload.isEmpty { return .ask }
        return classifyInternal(payload, depth: depth + 1)
    }

    /// `env [VAR=val…] [-flags] <command> …` — drop env's own prefix and classify the
    /// real command. Bare `env` (dump environment, possibly secrets) → gate.
    private static func classifyEnvWrapper(_ tokens: [String], depth: Int) -> ShellVerdict {
        guard depth < 4 else { return .ask }
        var rest = Array(tokens.dropFirst())   // drop "env"
        // Drop env's flags and inline VAR=val assignments (over-dropping is safe:
        // it can only make the remainder classify more conservatively).
        while let f = rest.first, f.hasPrefix("-") || (f.contains("=") && !f.hasPrefix("-")) {
            rest.removeFirst()
        }
        guard !rest.isEmpty else { return .ask }
        return classifyInternal(rest.joined(separator: " "), depth: depth + 1)
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

    /// `find` is safe for listing, but `-delete` / `-exec` / `-ok` make it a deletion
    /// or arbitrary-execution tool — treat those like `rm`: catastrophic root → deny,
    /// otherwise gate.
    private static func classifyFind(_ args: [String]) -> ShellVerdict {
        let destructive = args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) }
        if !destructive { return touchesSensitivePath(args) ? .ask : .allow }
        // A find rooted at the filesystem root / home / a system dir that also deletes
        // or executes is catastrophic.
        let roots = Array(args.prefix { !$0.hasPrefix("-") })
        return containsCatastrophicTarget(roots) ? .deny : .ask
    }

    // MARK: - Sensitive-path detection

    /// Paths whose contents are secrets or whose modification compromises the user.
    static func isSensitivePath(_ raw: String) -> Bool {
        let p = raw.lowercased()
        // Directories / dotfiles that hold credentials.
        let needles = [
            "/.ssh", "/.aws", "/.gnupg", "/.gcp", "/.azure", "/.kube",
            "/.npmrc", "/.netrc", "/.pgpass", "/.git-credentials",
            "/.docker/config", "/.config/gh", "/.cargo/credentials",
            "id_rsa", "id_ed25519", "id_dsa", "id_ecdsa",
            "/keychains", ".keychain", "credentials", "secrets",
            ".env",                       // .env, .env.local, …
            "authorized_keys", "known_hosts",
        ]
        if needles.contains(where: { p.contains($0) }) { return true }
        // System config / private-key file extensions.
        if p.hasPrefix("/etc/") || p.hasPrefix("/private/etc/") { return true }
        if p.hasSuffix(".pem") || p.hasSuffix(".key") || p.hasSuffix(".p12") || p.hasSuffix(".pfx") { return true }
        return false
    }

    private static func touchesSensitivePath(_ args: [String]) -> Bool {
        args.contains { arg in
            guard !arg.hasPrefix("-") else { return false }
            return isSensitivePath(arg)
        }
    }

    // MARK: - Catastrophic targets (shared by rm + find)

    private static func containsCatastrophicTarget(_ targets: [String]) -> Bool {
        targets.contains { t in
            if ["/", "~", "~/", "$HOME", "${HOME}", "/*", "~/*", "$HOME/*"].contains(t) { return true }
            // top-level system dir like /etc, /usr, /System (one path component, not /tmp or /var/folders)
            if t.hasPrefix("/"), !t.hasPrefix("/tmp"), !t.hasPrefix("/private"), !t.hasPrefix("/var/folders") {
                return t.dropFirst().split(separator: "/").count <= 1
            }
            return false
        }
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
        return containsCatastrophicTarget(targets)
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

    /// Any `>`/`>>` whose target escapes the project (absolute, `~`, or `..`) or lands
    /// on a secret / shell-rc file. fd-dup forms like `2>&1` are ignored.
    private static func redirectsOutsideProject(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"(?:^|[^0-9&])>>?\s*([^\s|;&<>()]+)"#) else { return false }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            let target = ns.substring(with: m.range(at: 1))
            if target.isEmpty || target.hasPrefix("&") { continue }
            if target.hasPrefix("/") || target.hasPrefix("~") || target.contains("..") { return true }
            if isSensitivePath(target) { return true }
            let rc = [".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile", ".zshenv"]
            let name = (target as NSString).lastPathComponent
            if rc.contains(name) { return true }
        }
        return false
    }

    // MARK: - Helpers

    /// Strip one matching pair of wrapping single/double quotes from a payload.
    private static func stripWrappingQuotes(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" else { return s }
        return String(s.dropFirst().dropLast())
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
