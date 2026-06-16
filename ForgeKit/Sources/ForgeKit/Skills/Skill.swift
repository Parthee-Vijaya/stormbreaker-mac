import Foundation

/// A reusable, user-extensible preset: a named prompt (+ optional mode) that the
/// user can trigger by name. Built-ins ship with Forge; users drop more as markdown
/// files in `~/.config/forge/skills/` (global) or `<project>/.forge/skills/` (project).
/// Borrowed from nanocoder's skill bundles — adapted to Forge's prompt-driven model.
public struct Skill: Sendable, Identifiable, Equatable {
    public enum Origin: String, Sendable, Equatable, Codable { case builtin, global, project }

    public var id: String
    public var name: String
    public var description: String
    public var icon: String
    /// Aliases the user can type (the canonical one is `id`). Defaults to `[id]`.
    public var triggers: [String]
    public var mode: AgentLoop.Mode
    /// The prompt the skill seeds. `{input}` is replaced with the user's extra text.
    public var prompt: String
    public var origin: Origin

    public init(
        id: String, name: String, description: String = "", icon: String = "sparkles",
        triggers: [String] = [], mode: AgentLoop.Mode = .build, prompt: String, origin: Origin = .builtin
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.triggers = triggers.isEmpty ? [id] : triggers
        self.mode = mode
        self.prompt = prompt
        self.origin = origin
    }

    /// Fill `{input}` with the user's extra text; if the template has no placeholder,
    /// append the input (or use the template alone when there's nothing extra).
    public func expand(input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.contains("{input}") {
            return prompt.replacingOccurrences(of: "{input}", with: trimmed)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? prompt : prompt + "\n\n" + trimmed
    }

    /// Parse a skill file: optional `---`-fenced frontmatter (simple `key: value`
    /// lines: id, name, description, icon, triggers, mode) followed by a markdown
    /// body that becomes `prompt`. Returns nil if there's no usable prompt body.
    public static func parse(_ text: String, id fallbackID: String, origin: Origin) -> Skill? {
        var meta: [String: String] = [:]
        var body = text
        let lines = text.components(separatedBy: "\n")

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<closeIdx] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { meta[key] = value }
            }
            body = closeIdx + 1 < lines.count ? lines[(closeIdx + 1)...].joined(separator: "\n") : ""
        }

        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        let id = (meta["id"].map { $0.isEmpty ? fallbackID : $0 }) ?? fallbackID
        let triggers = (meta["triggers"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let mode: AgentLoop.Mode = meta["mode"]?.lowercased() == "plan" ? .plan : .build

        return Skill(
            id: id,
            name: meta["name"] ?? id,
            description: meta["description"] ?? "",
            icon: meta["icon"] ?? "sparkles",
            triggers: triggers,
            mode: mode,
            prompt: prompt,
            origin: origin)
    }
}
