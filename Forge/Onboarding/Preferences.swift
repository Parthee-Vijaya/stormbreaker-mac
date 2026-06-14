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
    /// Auto-fix: when the running app throws a runtime error while idle, trigger
    /// a repair turn automatically (off by default — a "Fix it" button is always
    /// available regardless).
    var autoFix = false

    static let defaultRules = """
    # Project rules

    This app is React + Vite + TypeScript + Tailwind CSS v4.

    - Write production-quality, strongly-typed, modular React.
    - Use Tailwind utility classes; keep a clean, consistent aesthetic.
    - Prefer few, well-chosen dependencies.
    - Use real, intent-revealing content (no lorem ipsum).
    """

    init() {}
}

/// Tolerant decoding: start from defaults and override only the keys that are
/// present. Swift's synthesized Decodable throws on a missing non-optional key,
/// which would otherwise reset ALL preferences (and re-trigger onboarding) the
/// first time a new field is added to an existing install. This makes the struct
/// safe to extend forever.
extension Preferences {
    enum CodingKeys: String, CodingKey {
        case onboarded, userName, projectsRoot, defaultModelID, cloudProvider
        case cloudModel, githubOwner, vercelScope, memory, rulesTemplate, autoFix
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboarded = (try? c.decode(Bool.self, forKey: .onboarded)) ?? onboarded
        userName = (try? c.decode(String.self, forKey: .userName)) ?? userName
        projectsRoot = (try? c.decode(String.self, forKey: .projectsRoot)) ?? projectsRoot
        defaultModelID = (try? c.decode(String.self, forKey: .defaultModelID)) ?? defaultModelID
        cloudProvider = (try? c.decode(String.self, forKey: .cloudProvider)) ?? cloudProvider
        cloudModel = (try? c.decode(String.self, forKey: .cloudModel)) ?? cloudModel
        githubOwner = (try? c.decode(String.self, forKey: .githubOwner)) ?? githubOwner
        vercelScope = (try? c.decode(String.self, forKey: .vercelScope)) ?? vercelScope
        memory = (try? c.decode(String.self, forKey: .memory)) ?? memory
        rulesTemplate = (try? c.decode(String.self, forKey: .rulesTemplate)) ?? rulesTemplate
        autoFix = (try? c.decode(Bool.self, forKey: .autoFix)) ?? autoFix
    }
}
