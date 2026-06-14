import Foundation

/// The seam between the artifact executor (engine) and the process/dev-server
/// layer. The executor depends only on this protocol, so tests inject a mock.
public protocol ProcessLayer: Sendable {
    func writeFile(_ relativePath: String, contents: String) async throws

    /// Read a file's current contents (used to apply line-replace edits).
    func readFile(_ relativePath: String) async throws -> String

    /// Install npm packages (adds them to package.json). No-op for an empty list.
    func addDependencies(_ packages: [String]) async throws

    /// Run an arbitrary shell command; returns its exit code.
    @discardableResult
    func runShell(_ command: String) async throws -> Int32

    /// Start the dev server if it isn't already running; returns the local URL.
    @discardableResult
    func startDevServerIfNeeded() async throws -> URL

    /// The current dev-server URL, or nil if not running.
    var serverReadyURL: URL? { get async }
}
