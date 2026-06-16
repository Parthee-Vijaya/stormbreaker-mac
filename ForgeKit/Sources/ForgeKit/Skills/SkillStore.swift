import Foundation

/// Loads skills from three layers (project overrides global overrides built-in,
/// matched by `id`): the shipped built-ins, the user's global skills directory
/// (`~/.config/forge/skills/`), and the project's `.forge/skills/`.
public enum SkillStore {
    /// Shipped presets — the same starting points as the GUI's template gallery /
    /// quick actions, now expressible (and overridable) as skills.
    public static let builtins: [Skill] = [
        Skill(id: "todo", name: "Todo-app", description: "Tilføj, fuldfør, filtrér, gem",
              icon: "checklist", triggers: ["todo", "opgaver"],
              prompt: "Byg en to-do app: tilføj opgaver med Enter, marker som færdig, slet en opgave, filtrér (alle/aktive/færdige), og gem alt i localStorage. Ren, moderne UI. {input}"),
        Skill(id: "landing", name: "Landingsside", description: "Hero, features, priser, CTA",
              icon: "rectangle.on.rectangle", triggers: ["landing", "landingsside"],
              prompt: "Byg en moderne, responsiv landingsside for et produkt: hero med stærk overskrift + CTA-knap, feature-grid med 3 kort, en pris-sektion med 3 niveauer, og en footer. {input}"),
        Skill(id: "dashboard", name: "Dashboard", description: "Sidebar, stat-kort, graf, tabel",
              icon: "chart.bar.xaxis", triggers: ["dashboard"],
              prompt: "Byg et admin-dashboard: venstre sidebar med navigation, en top-bar, 4 stat-kort øverst, et linjediagram og en data-tabel med eksempeldata. Mørk, professionel stil. {input}"),
        Skill(id: "fix", name: "Ret fejl", description: "Find og ret fejlene i appen",
              icon: "wrench.and.screwdriver", triggers: ["fix", "ret"],
              prompt: "Find og ret fejlene i den nuværende app, så den bygger og kører rent. {input}"),
        Skill(id: "responsive", name: "Gør responsiv", description: "Mobil/tablet/desktop",
              icon: "iphone", triggers: ["responsive", "mobil"],
              prompt: "Gør den nuværende app fuldt responsiv på mobil, tablet og desktop uden at ændre funktionaliteten. {input}"),
        Skill(id: "plan", name: "Planlæg", description: "Læg en plan uden at skrive kode",
              icon: "list.bullet.clipboard", triggers: ["plan", "planlæg"], mode: .plan,
              prompt: "Læg en kort, konkret plan for hvordan vi bygger følgende — trin for trin, uden at skrive kode endnu: {input}"),
    ]

    /// `~/.config/forge/skills` (or `$XDG_CONFIG_HOME/forge/skills`).
    public static func globalDir() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("forge/skills")
    }

    /// Built-ins + global + project, deduped by id (later layers win).
    public static func load(projectRoot: URL? = nil) -> [Skill] {
        var byID: [String: Skill] = [:]
        for s in builtins { byID[s.id] = s }
        for s in loadDir(globalDir(), origin: .global) { byID[s.id] = s }
        if let root = projectRoot {
            for s in loadDir(root.appendingPathComponent(".forge/skills"), origin: .project) { byID[s.id] = s }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a skill by id or any trigger (case-insensitive).
    public static func find(_ token: String, in skills: [Skill]) -> Skill? {
        let t = token.lowercased()
        return skills.first { $0.id.lowercased() == t || $0.triggers.contains { $0.lowercased() == t } }
    }

    static func loadDir(_ dir: URL, origin: Skill.Origin) -> [Skill] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Skill.parse(text, id: url.deletingPathExtension().lastPathComponent, origin: origin)
            }
    }
}
