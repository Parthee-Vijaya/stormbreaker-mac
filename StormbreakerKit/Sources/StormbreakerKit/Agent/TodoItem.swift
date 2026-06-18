import Foundation

/// One item in the agent's live plan checklist (todowrite-style). The model emits a
/// `<forgeAction type="todo">` block whose body is one item per line; re-emitting the
/// block with updated markers updates the list in place.
public struct TodoItem: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case pending, active, done }
    public let text: String
    public let status: Status
    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }

    /// Parse a todo block body into items. Each non-empty line may carry a checkbox
    /// marker: `[x]` done, `[~]`/`[-]`/`[>]`/`[*]`/`[/]` in-progress, `[ ]`/`[]`/none
    /// pending. A leading `- ` bullet is tolerated. Lines with no marker become pending.
    public static func parse(_ body: String) -> [TodoItem] {
        var items: [TodoItem] = []
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("- ") { line.removeFirst(2) }
            else if line.hasPrefix("* ") { line.removeFirst(2) }
            var status: Status = .pending
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let inner = line[line.index(after: line.startIndex)..<close]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                switch inner {
                case "x": status = .done
                case "~", "-", ">", "*", "/": status = .active
                default: status = .pending           // "" or " "
                }
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty { items.append(TodoItem(text: line, status: status)) }
        }
        return items
    }

    /// Detect a markdown task-list in free prose (`- [ ] item`, `* [x] item`,
    /// `1. [~] item`) and return the LONGEST contiguous run — a fallback for models
    /// that write a plan as prose instead of a todo action. nil if fewer than 2 lines.
    public static func fromProse(_ text: String) -> [TodoItem]? {
        var run: [TodoItem] = [], best: [TodoItem] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let item = proseLine(line) {
                run.append(item)
                if run.count > best.count { best = run }
            } else if !line.isEmpty {
                run = []                                  // a non-checklist line breaks the run
            }
        }
        return best.count >= 2 ? best : nil
    }

    private static func proseLine(_ line: String) -> TodoItem? {
        guard line.range(of: #"^([-*]|\d+\.)\s+\["#, options: .regularExpression) != nil,
              let box = line.range(of: #"\[[ xX~/>\-]?\]"#, options: .regularExpression) else { return nil }
        let rest = String(line[box.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let inner = line[box].dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
        let status: Status = inner == "x" ? .done : (["~", "/", "-", ">"].contains(inner) ? .active : .pending)
        return TodoItem(text: rest, status: status)
    }
}
