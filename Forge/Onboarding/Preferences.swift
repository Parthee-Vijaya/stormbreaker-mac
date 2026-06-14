import Foundation

/// User-level configuration set in onboarding and editable in Settings.
struct Preferences: Codable, Equatable {
    var onboarded = false
    var userName = ""
    /// Empty = use the default location (Application Support/Forge/projects).
    var projectsRoot = ""
    var defaultModelID = ""
    /// "ollama" handled by discovery; cloud provider for the entered key.
    var cloudProvider = ""          // "nvidiaNIM" | "openai" | "anthropic" | ""
    var cloudModel = ""
    var githubOwner = ""
    var vercelScope = ""
    var memory = ""
    var rulesTemplate = Preferences.defaultRules

    static let defaultRules = """
    # Project rules

    This app is React + Vite + TypeScript + Tailwind CSS v4.

    - Write production-quality, strongly-typed, modular React.
    - Use Tailwind utility classes; keep a clean, consistent aesthetic.
    - Prefer few, well-chosen dependencies.
    - Use real, intent-revealing content (no lorem ipsum).
    """
}
