import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ReviewAgent (agentic-SDLC borrow) — a SECOND agent that reviews a build after it
// converges, collapsing the post's Reviewer/QA/Security personas into one pass with
// three lenses: correctness (does it do what was asked?), security, and a11y. It
// reads the user's request + the unified diff and returns structured findings. The
// app + CLI both drive it; auto-fix feeds the findings back as a normal build turn.
// ─────────────────────────────────────────────────────────────────────────────

public struct ReviewFinding: Sendable, Equatable {
    public enum Severity: String, Sendable { case critical, warn, info, ok }
    public let severity: Severity
    public let category: String   // correctness · security · a11y · quality
    public let file: String?
    public let message: String
    public init(severity: Severity, category: String, file: String?, message: String) {
        self.severity = severity; self.category = category; self.file = file; self.message = message
    }
}

public struct ReviewReport: Sendable, Equatable {
    public var findings: [ReviewFinding]
    public var summary: String
    public init(findings: [ReviewFinding] = [], summary: String = "") {
        self.findings = findings; self.summary = summary
    }
    /// Warn/critical findings — the ones worth surfacing + auto-fixing.
    public var actionable: [ReviewFinding] { findings.filter { $0.severity == .warn || $0.severity == .critical } }
    public var isClean: Bool { actionable.isEmpty }
}

/// A focused review lens — one specialised agent per lens runs in parallel in a
/// review panel, each looking only at its own domain (so each finding is sharper
/// than one generalist pass).
public enum ReviewLens: String, Sendable, CaseIterable {
    case correctness, security, frontend, backend

    public var label: String {
        switch self {
        case .correctness: return "korrekthed"
        case .security:    return "sikkerhed"
        case .frontend:    return "frontend"
        case .backend:     return "backend"
        }
    }

    var focus: String {
        switch self {
        case .correctness:
            return "Fokusér KUN på korrekthed: gør koden det brugeren bad om? Logiske fejl, edge cases, brudt eller manglende state, runtime-crash, forkerte betingelser, glemte tilfælde."
        case .security:
            return "Fokusér KUN på sikkerhed: XSS / dangerouslySetInnerHTML, hemmeligheder eller API-nøgler i koden, usikker fetch/eval, ufiltreret bruger-input, manglende validering."
        case .frontend:
            return "Fokusér KUN på frontend/UI: tilgængelighed (alt/aria/labels/tastatur/kontrast), responsivt design, React-mønstre (keys, hooks-regler, unødvendige re-renders), UX-detaljer."
        case .backend:
            return "Fokusér KUN på backend/server: API-kald, datahåndtering, fejlhåndtering, async/await-fejl, race conditions. Hvis ÆNDRINGERNE ikke indeholder backend/server-kode, så output KUN: SUMMARY :: Ingen backend-kode."
        }
    }
}

public struct ReviewAgent: Sendable {
    public init() {}

    /// Review `diff` (what the turn changed) against the user's `request`. One model
    /// call; returns parsed findings. A model/parse failure yields an empty report
    /// (review is advisory — it never blocks the build).
    public func review(request: String, diff: String,
                       provider: any ChatModel, options: GenerationOptions) async -> ReviewReport {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ReviewReport(summary: "Ingen ændringer at gennemgå.")
        }
        let user = """
        ANMODNING:
        \(request)

        ÆNDRINGER (unified diff):
        \(String(diff.prefix(14000)))
        """
        var text = ""
        do {
            for try await ev in provider.stream(
                messages: [ChatMessage(role: .system, content: Self.systemPrompt),
                           ChatMessage(role: .user, content: user)],
                options: options) {
                if case .token(let t) = ev { text += t }
            }
        } catch {
            return ReviewReport(summary: "Review kunne ikke køre.")
        }
        return Self.parse(text)
    }

    /// Review through a single lens. Same as `review`, but with the lens's focused
    /// system prompt; findings are re-tagged with the lens so the panel can group them.
    public func review(request: String, diff: String, lens: ReviewLens,
                       provider: any ChatModel, options: GenerationOptions) async -> ReviewReport {
        let user = """
        ANMODNING:
        \(request)

        ÆNDRINGER (unified diff):
        \(String(diff.prefix(14000)))
        """
        var text = ""
        do {
            for try await ev in provider.stream(
                messages: [ChatMessage(role: .system, content: Self.systemPrompt(for: lens)),
                           ChatMessage(role: .user, content: user)],
                options: options) {
                if case .token(let t) = ev { text += t }
            }
        } catch {
            return ReviewReport()
        }
        let parsed = Self.parse(text)
        // Force the category to the lens so the merged report groups consistently.
        let tagged = parsed.findings.map {
            ReviewFinding(severity: $0.severity, category: lens.label, file: $0.file, message: $0.message)
        }
        return ReviewReport(findings: tagged, summary: parsed.summary)
    }

    /// Spin up one specialised agent per lens IN PARALLEL, then merge their findings
    /// into a single report. This is the multi-agent review panel.
    public func reviewPanel(request: String, diff: String,
                            lenses: [ReviewLens] = ReviewLens.allCases,
                            provider: any ChatModel, options: GenerationOptions) async -> ReviewReport {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ReviewReport(summary: "Ingen ændringer at gennemgå.")
        }
        let me = self
        let reports = await withTaskGroup(of: ReviewReport.self) { group -> [ReviewReport] in
            for lens in lenses {
                group.addTask { await me.review(request: request, diff: diff, lens: lens, provider: provider, options: options) }
            }
            var acc: [ReviewReport] = []
            for await r in group { acc.append(r) }
            return acc
        }
        return Self.merge(reports, lensCount: lenses.count)
    }

    /// Combine per-lens reports: flatten, dedupe by file+message, sort criticals
    /// first, and build a one-line summary. Pure — unit-tested.
    public static func merge(_ reports: [ReviewReport], lensCount: Int) -> ReviewReport {
        var seen = Set<String>()
        var deduped: [ReviewFinding] = []
        for f in reports.flatMap({ $0.findings }) {
            let key = (f.file ?? "-").lowercased() + "|" + f.message.lowercased()
            if seen.insert(key).inserted { deduped.append(f) }
        }
        let order: [ReviewFinding.Severity: Int] = [.critical: 0, .warn: 1, .info: 2, .ok: 3]
        deduped.sort { (order[$0.severity] ?? 9) < (order[$1.severity] ?? 9) }
        let actionable = deduped.filter { $0.severity == .warn || $0.severity == .critical }.count
        let summary = actionable == 0
            ? "\(lensCount) agenter gennemgik — ser godt ud."
            : "\(lensCount) agenter fandt \(actionable) ting."
        return ReviewReport(findings: deduped, summary: summary)
    }

    static func systemPrompt(for lens: ReviewLens) -> String {
        """
        Du er en SPECIALISERET kode-reviewer for små web-apps (React/Vite/Tailwind/TypeScript).
        Du får brugerens ANMODNING og de ÆNDRINGER (unified diff) en AI lige har lavet.
        \(lens.focus)
        Vær kortfattet og konkret. Ignorér stil og smag. Nævn KUN ægte problemer i dit fokusområde.

        Output KUN linjer i præcis dette format (én pr. fund), og intet andet:
        SEVERITY :: KATEGORI :: FIL :: BESKED
        SEVERITY er én af: critical, warn, info.  KATEGORI er: \(lens.label).
        FIL er stien (fx src/App.tsx) eller "-" hvis uklart. BESKED er kort, på dansk.
        Afslut ALTID med præcis én linje:
        SUMMARY :: <kort dom på dansk>
        Hvis der ingen problemer er, så output KUN: SUMMARY :: Ser godt ud.
        """
    }

    static let systemPrompt = """
    Du er en erfaren kode-reviewer for små web-apps (React/Vite/Tailwind/TypeScript).
    Du får brugerens ANMODNING og de ÆNDRINGER (unified diff) en AI lige har lavet.
    Find KONKRETE problemer i tre kategorier:
    - correctness: gør koden det, brugeren faktisk bad om? mangler der noget?
    - security: oplagte fejl (XSS/dangerouslySetInnerHTML, hemmeligheder i koden, usikre fetch).
    - a11y: tilgængelighed (manglende alt/aria-label, knapper uden navn, tastatur, kontrast).
    Vær kortfattet og konkret. Ignorér stil og smag. Nævn KUN ægte problemer.

    Output KUN linjer i præcis dette format (én pr. fund), og intet andet:
    SEVERITY :: KATEGORI :: FIL :: BESKED
    SEVERITY er én af: critical, warn, info.  KATEGORI er: correctness, security eller a11y.
    FIL er stien (fx src/App.tsx) eller "-" hvis uklart. BESKED er kort, på dansk.
    Afslut ALTID med præcis én linje:
    SUMMARY :: <kort dom på dansk>
    Hvis der ingen problemer er, så output KUN: SUMMARY :: Ser godt ud.
    """

    /// Parse the delimited reviewer output. Lenient: skips malformed lines, accepts a
    /// trailing SUMMARY, and tolerates leading list markers / code fences.
    public static func parse(_ raw: String) -> ReviewReport {
        var findings: [ReviewFinding] = []
        var summary = ""
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") || line.hasPrefix("`") {
                line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces)
            }
            let parts = line.components(separatedBy: "::").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let head = parts[0].lowercased()
            if head == "summary" {
                summary = parts.dropFirst().joined(separator: " :: ")
                continue
            }
            guard let sev = ReviewFinding.Severity(rawValue: head), parts.count >= 4 else { continue }
            let file = parts[2].isEmpty || parts[2] == "-" ? nil : parts[2]
            let message = parts[3...].joined(separator: " :: ")
            guard !message.isEmpty else { continue }
            findings.append(ReviewFinding(severity: sev, category: parts[1].lowercased(), file: file, message: message))
        }
        return ReviewReport(findings: findings, summary: summary)
    }

    /// Turn actionable findings into a follow-up build instruction (auto-fix).
    public static func fixPrompt(for report: ReviewReport) -> String {
        let lines = report.actionable.map { f -> String in
            "- [\(f.category)] \(f.file.map { "\($0): " } ?? "")\(f.message)"
        }.joined(separator: "\n")
        return "En reviewer fandt disse problemer ved den seneste ændring. Ret dem — og kun dem:\n\(lines)"
    }
}
