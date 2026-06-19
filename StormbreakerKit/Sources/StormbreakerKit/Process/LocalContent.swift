import Foundation

/// Reads a filesystem path the user referenced in a prompt — a file's contents or a
/// directory listing — so the agent answers from REAL content instead of guessing or
/// pretending ("Læser…" then building something unrelated). This is the local-path
/// twin of `WebContent`: read-only, user-directed, capped. The agent can READ anywhere
/// the user points; it still only WRITES inside the project workspace (jailed).
public enum LocalContent {

    /// Read a resolved path: file → "FIL: …\n\n<contents>"; directory → "MAPPE: …\n<listing>".
    /// Returns nil if the path doesn't exist. Skips binary/huge files gracefully.
    public static func read(_ path: String, maxChars: Int = 8000, maxEntries: Int = 300) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue
            ? listing(path, fm: fm, maxEntries: maxEntries, maxChars: maxChars)
            : fileContents(path, maxChars: maxChars)
    }

    /// Expand `~`, then find the LONGEST existing path by trimming trailing words and
    /// path segments — so "/Users/x/Desktop/\ -\ kan\ du" resolves to "/Users/x/Desktop".
    /// nil if nothing along the way exists. Only resolves absolute / home paths.
    public static func resolveExisting(_ raw: String) -> String? {
        let unescaped = raw.replacingOccurrences(of: "\\ ", with: " ").replacingOccurrences(of: "\\", with: "")
        func norm(_ s: String) -> String { var x = s; while x.hasSuffix("/"), x != "/" { x.removeLast() }; return x }
        var p = norm(expand(unescaped).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?)]}\"'")))
        guard p.hasPrefix("/") else { return nil }
        if FileManager.default.fileExists(atPath: p) { return p }
        // Strip trailing words first (handles "…/Desktop - kan du"), then path segments.
        while p.count > 1 {
            if let sp = p.range(of: " ", options: .backwards) { p = String(p[..<sp.lowerBound]) }
            else if let sl = p.range(of: "/", options: .backwards) { p = String(p[..<sl.lowerBound]) }
            else { break }
            p = norm(p.trimmingCharacters(in: .whitespaces))
            guard p.hasPrefix("/"), p != "/" else { break }
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Extract candidate absolute/home path tokens from free text (tolerates `\ ` escapes).
    public static func extractPaths(_ text: String) -> [String] {
        // /abs or ~/home, then non-space chars OR backslash-escaped chars.
        let pattern = #"(?:~/|/)(?:\\.|[^\s])*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>(); var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            // Skip bare "/" and single-segment noise like "/" or "/a" with no real depth.
            guard tok.count > 2, tok.contains("/") else { continue }
            if seen.insert(tok).inserted { out.append(tok) }
        }
        return out
    }

    // MARK: - Internals

    static func expand(_ p: String) -> String {
        var s = p
        if s == "~" { s = NSHomeDirectory() }
        else if s.hasPrefix("~/") { s = NSHomeDirectory() + String(s.dropFirst()) }
        return (s as NSString).standardizingPath
    }

    static func fileContents(_ path: String, maxChars: Int) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > 2_000_000 { return "FIL: \(path)\n(\(size) bytes — for stor til at vise)" }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.prefix(8000).contains(0) { return "FIL: \(path)\n(\(size) bytes — binær fil, vises ikke)" }
        return "FIL: \(path)\n\n" + String(String(decoding: data, as: UTF8.self).prefix(maxChars))
    }

    static func listing(_ path: String, fm: FileManager, maxEntries: Int, maxChars: Int) -> String {
        // Recursive tree (≤ 3 levels) so NESTED files show too — e.g. public/bjarne-ja.jpeg,
        // not just "public/". Skips heavy build dirs; capped by entry count + chars.
        let skip: Set<String> = ["node_modules", ".git", ".next", "dist", "build", ".DS_Store", ".cache"]
        var lines: [String] = []
        var count = 0
        func walk(_ dir: URL, depth: Int, indent: String) {
            guard depth <= 3, count < maxEntries else { return }
            let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            for item in items {
                if count >= maxEntries { lines.append(indent + "…"); return }
                if skip.contains(item.lastPathComponent) { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                lines.append(indent + item.lastPathComponent + (isDir ? "/" : ""))
                count += 1
                if isDir { walk(item, depth: depth + 1, indent: indent + "  ") }
            }
        }
        walk(URL(fileURLWithPath: path), depth: 1, indent: "  ")
        return String((["MAPPE: \(path)  (\(count) elementer, rekursivt)"] + lines)
            .joined(separator: "\n").prefix(maxChars))
    }
}
