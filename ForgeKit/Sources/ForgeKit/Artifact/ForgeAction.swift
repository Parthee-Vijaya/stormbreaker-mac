import Foundation

/// One action parsed from a model artifact. Whole-file writes are the default;
/// `lineReplace` is a search/replace diff used by strong models for small,
/// targeted edits to existing files (gated on `ModelConfig.supportsLineReplace`).
public enum ForgeAction: Sendable, Equatable {
    case file(path: String, contents: String)
    case lineReplace(path: String, edits: [LineEdit])
    case shell(command: String)
    case start(command: String)
    case addDependency(package: String)
}

/// One search/replace block: find `search` (matched exactly) and swap in
/// `replace`. Multiple edits may apply to one file in order.
public struct LineEdit: Sendable, Equatable {
    public let search: String
    public let replace: String
    public init(search: String, replace: String) {
        self.search = search
        self.replace = replace
    }
}
