import Foundation

/// The frontend framework a project is scaffolded with. React/Svelte/Vue are all
/// Vite-based (identical dev server, ready-detection and `npm run dev` flow) — only
/// the template files and the system-prompt guidance differ. Next.js (B7) is NOT
/// Vite: it runs `next dev` (port 3000) and uses the app router, but it prints the
/// same "Local: http://localhost:…" ready line, so the existing detector + the
/// generic `npm run dev` path carry it without dev-server changes.
public enum Framework: String, Sendable, CaseIterable {
    case react, svelte, vue, nextjs

    public init(id: String) { self = Framework(rawValue: id) ?? .react }

    public var displayName: String {
        switch self {
        case .react: "React"
        case .svelte: "Svelte"
        case .vue: "Vue"
        case .nextjs: "Next.js"
        }
    }

    public var template: ProjectTemplate {
        switch self {
        case .react: .viteReactTailwind
        case .svelte: .viteSvelteTailwind
        case .vue: .viteVueTailwind
        case .nextjs: .nextjsTailwind
        }
    }
}
