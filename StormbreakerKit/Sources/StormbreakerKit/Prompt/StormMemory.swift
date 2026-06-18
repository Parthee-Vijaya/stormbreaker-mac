import Foundation

/// One thing Stormbreaker remembers across sessions — a user preference, a project
/// decision, a convention, a fact, or a correction. Stored as plain JSON (no vector
/// DB, no daemon): the memory set is small, so "include all, token-budgeted" beats
/// semantic search. Borrowed from iai-personal-memory-engine, reimplemented native.
public struct MemoryEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case preference, decision, fact, convention, correction, note
    }
    public var id: String
    public var text: String
    public var kind: Kind
    public var createdAt: Date
    /// id of the entry that replaced this one (supersede-don't-delete). nil = active.
    public var supersededBy: String?

    public var isActive: Bool { supersededBy == nil }

    public init(id: String = UUID().uuidString, text: String, kind: Kind = .note,
                createdAt: Date = Date(), supersededBy: String? = nil) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.createdAt = createdAt
        self.supersededBy = supersededBy
    }
}

public enum MemoryScope: String, Sendable, Codable { case global, project }

/// Cross-session memory: a `global` store (about the user, applies everywhere) plus a
/// `project` store (about this codebase). Both are plain JSON files the user can read
/// and edit. Loaded synchronously (small), injected into the system prompt each turn.
public struct StormMemory: Sendable {
    public let globalURL: URL
    public let projectURL: URL
    private var global: [MemoryEntry]
    private var project: [MemoryEntry]

    public init(globalURL: URL, projectURL: URL) {
        self.globalURL = globalURL
        self.projectURL = projectURL
        self.global = Self.read(globalURL)
        self.project = Self.read(projectURL)
    }

    /// Active entries across both scopes, newest first.
    public var active: [(scope: MemoryScope, entry: MemoryEntry)] {
        let g = global.filter(\.isActive).map { (MemoryScope.global, $0) }
        let p = project.filter(\.isActive).map { (MemoryScope.project, $0) }
        return (g + p).sorted { $0.1.createdAt > $1.1.createdAt }
    }

    public var isEmpty: Bool { active.isEmpty }

    /// Add a memory unless a near-duplicate is already active. Returns false if skipped.
    @discardableResult
    public mutating func remember(_ text: String, kind: MemoryEntry.Kind = .note,
                                  scope: MemoryScope = .project) -> Bool {
        let entry = MemoryEntry(text: text, kind: kind)
        guard !entry.text.isEmpty else { return false }
        guard !list(scope).contains(where: { $0.isActive && Self.similar($0.text, entry.text) }) else { return false }
        mutate(scope) { $0.append(entry) }
        save(scope)
        return true
    }

    /// Forget the active entry at `displayIndex` (its position in `active`). Deletes it
    /// outright — explicit forget, unlike conflict-supersede.
    @discardableResult
    public mutating func forget(_ displayIndex: Int) -> MemoryEntry? {
        let act = active
        guard act.indices.contains(displayIndex) else { return nil }
        let (scope, entry) = act[displayIndex]
        mutate(scope) { $0.removeAll { $0.id == entry.id } }
        save(scope)
        return entry
    }

    /// Ingest model-extracted facts (Phase 2): dedup against active entries, and when a
    /// new fact CONTRADICTS an existing one, supersede the old (keep it, mark replaced).
    /// Returns the count actually added.
    @discardableResult
    public mutating func ingest(_ facts: [(scope: MemoryScope, kind: MemoryEntry.Kind, text: String, supersedes: String?)]) -> Int {
        var added = 0
        for fact in facts {
            let entry = MemoryEntry(text: fact.text, kind: fact.kind)
            guard !entry.text.isEmpty else { continue }
            if list(fact.scope).contains(where: { $0.isActive && Self.similar($0.text, entry.text) }) { continue }
            // Supersede an old active entry this fact replaces (by similarity to `supersedes`).
            if let old = fact.supersedes, !old.isEmpty {
                mutate(fact.scope) { arr in
                    for i in arr.indices where arr[i].isActive && Self.similar(arr[i].text, old) {
                        arr[i].supersededBy = entry.id
                    }
                }
            }
            mutate(fact.scope) { $0.append(entry) }
            added += 1
        }
        if added > 0 { save(.global); save(.project) }
        return added
    }

    /// The memory block injected into the system prompt, token-budgeted (newest first).
    public func promptBlock(budgetTokens: Int = 1000) -> String? {
        let act = active
        guard !act.isEmpty else { return nil }
        let header = "What you already know about the user and this project (their saved memory — "
            + "honor it; don't ask again for things listed here):"
        var used = ContextBuilder.estimateTokens(header)
        var lines: [String] = []
        for (scope, e) in act {
            let line = "- (\(scope.rawValue)/\(e.kind.rawValue)) \(e.text)"
            let cost = ContextBuilder.estimateTokens(line)
            if used + cost > budgetTokens { break }
            lines.append(line); used += cost
        }
        return lines.isEmpty ? nil : header + "\n" + lines.joined(separator: "\n")
    }

    // MARK: - Internals

    private func list(_ scope: MemoryScope) -> [MemoryEntry] { scope == .global ? global : project }
    private mutating func mutate(_ scope: MemoryScope, _ f: (inout [MemoryEntry]) -> Void) {
        if scope == .global { f(&global) } else { f(&project) }
    }
    private func save(_ scope: MemoryScope) {
        Self.write(scope == .global ? global : project, to: scope == .global ? globalURL : projectURL)
    }

    static func read(_ url: URL) -> [MemoryEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return [] }
        return entries
    }
    public static func write(_ entries: [MemoryEntry], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(entries) { try? data.write(to: url) }
    }

    /// Near-duplicate test: Jaccard overlap of word sets ≥ 0.8 (cheap, no embeddings).
    /// Too few meaningful words for a reliable Jaccard → require an exact (normalized)
    /// match instead, so short distinct facts don't collapse together.
    static func similar(_ a: String, _ b: String) -> Bool {
        let wa = words(a), wb = words(b)
        if wa.count < 2 || wb.count < 2 { return normalize(a) == normalize(b) }
        let inter = wa.intersection(wb).count
        return Double(inter) / Double(wa.union(wb).count) >= 0.8
    }
    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }
    private static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
