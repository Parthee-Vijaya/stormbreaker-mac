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

    /// Multi-model roles (B25). Each holds a ModelConfig.id; empty = fall back to
    /// the currently-selected model. The copy model localizes user-facing text to
    /// Danish in a post-build pass; an empty `copyModelID` means no copy-pass.
    var planModelID = ""
    var buildModelID = ""
    var copyModelID = ""
    /// Run the Danish copy-pass automatically after a successful build (only when
    /// a copy model is set).
    var autoCopyPass = false

    /// Learning mode (beginner): show contextual explainer cards at milestones,
    /// a glossary, and a more beginner-friendly AI tone. `learnedLessons` holds
    /// the ids of explainers already shown, so each appears only once.
    var learningMode = false
    var learnedLessons: [String] = []

    /// How the user likes to be addressed in the start-screen greeting ("Hvad vil
    /// du bygge, P?"). Asked once via a popup; editable in Settings.
    /// `askedPreferredName` stops the popup from re-appearing if left blank.
    var preferredName = ""
    var askedPreferredName = false

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
        case planModelID, buildModelID, copyModelID, autoCopyPass
        case learningMode, learnedLessons
        case preferredName, askedPreferredName
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
        planModelID = (try? c.decode(String.self, forKey: .planModelID)) ?? planModelID
        buildModelID = (try? c.decode(String.self, forKey: .buildModelID)) ?? buildModelID
        copyModelID = (try? c.decode(String.self, forKey: .copyModelID)) ?? copyModelID
        autoCopyPass = (try? c.decode(Bool.self, forKey: .autoCopyPass)) ?? autoCopyPass
        learningMode = (try? c.decode(Bool.self, forKey: .learningMode)) ?? learningMode
        learnedLessons = (try? c.decode([String].self, forKey: .learnedLessons)) ?? learnedLessons
        preferredName = (try? c.decode(String.self, forKey: .preferredName)) ?? preferredName
        askedPreferredName = (try? c.decode(Bool.self, forKey: .askedPreferredName)) ?? askedPreferredName
    }
}
