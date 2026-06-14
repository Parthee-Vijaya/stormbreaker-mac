import Foundation

/// A deduplicated set of errors for one self-correction turn.
public struct ErrorReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Hashable {
        public enum Source: String, Sendable { case build, runtime }
        public let source: Source
        public let message: String
        /// Structured location, when the classifier could parse it
        /// (e.g. `src/App.tsx`, line 12, code `TS2304`).
        public let file: String?
        public let line: Int?
        public let code: String?

        public init(
            source: Source,
            message: String,
            file: String? = nil,
            line: Int? = nil,
            code: String? = nil
        ) {
            self.source = source
            self.message = message
            self.file = file
            self.line = line
            self.code = code
        }

        /// Dedup key: structured (file + line + code) when available, else the
        /// message with numbers normalized away. Collapses the same error
        /// reported by both tsc and the Vite overlay into one item.
        var dedupKey: String {
            if let file {
                return "\(file):\(line.map(String.init) ?? "?"):\(code ?? "")"
            }
            return Self.normalize(message)
        }

        static func normalize(_ text: String) -> String {
            text
                .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
    }

    public var items: [Item]

    public init(items: [Item] = []) { self.items = items }

    public var isClean: Bool { items.isEmpty }

    public func formatted() -> String {
        items.map { item in
            var prefix = "[\(item.source.rawValue)]"
            if let file = item.file {
                prefix += " \(file)"
                if let line = item.line { prefix += ":\(line)" }
            }
            if let code = item.code { prefix += " \(code)" }
            return "\(prefix) \(item.message)"
        }.joined(separator: "\n")
    }

    /// Stable fingerprint used by the loop's no-progress guard so a repeated
    /// error set stops the loop. Line/column numbers are normalized away (they
    /// drift between attempts); file + code + message-shape are what matter.
    public var signature: String {
        items.map { item -> String in
            if let file = item.file {
                return "\(file):\(item.code ?? ""):\(Item.normalize(item.message))"
            }
            return Item.normalize(item.message)
        }
        .sorted()
        .joined(separator: "|")
    }
}
