/// Starter AGENTS.md written by /init. AGENTS.md is the cross-tool convention that
/// RulesLoader reads every turn (alongside AI_RULES.md), so the project's house
/// rules are honored automatically after /init.
enum AgentsTemplate {
    static func render(project: String, framework: String) -> String {
        """
        # AGENTS.md — \(project)

        Projekt-regler som Forge (og andre AI-værktøjer) læser før hver tur.

        ## Stak
        - \(framework) + Vite + Tailwind + shadcn/ui.
        - TypeScript i strict mode — ingen `any`.

        ## Konventioner
        - Dansk UI-tekst medmindre andet bedes om.
        - Små, fokuserede komponenter; genbrug shadcn/ui-komponenter frem for at bygge fra bunden.
        - Hold ændringer minimale og målrettede til det, der spørges om.

        ## Husk
        - (tilføj jeres egne regler her — fx farver, tone, mappestruktur)
        """
    }
}
