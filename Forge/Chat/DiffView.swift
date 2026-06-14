import SwiftUI

/// Renders a unified git diff in a sheet: additions green, deletions red, hunk
/// headers faint. Shown from a turn's "View changes" action.
struct DiffView: View {
    let diff: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().overlay(Theme.border)

            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack { Spacer(); Text("No changes.").font(.system(size: 13)).foregroundStyle(Theme.inkSoft); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 0.5)
                                .background(background(for: line))
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 680, height: 540)
        .background(Theme.canvas)
        .preferredColorScheme(.light)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return Theme.inkFaint
        }
        if line.hasPrefix("@@") { return Theme.accent.opacity(0.7) }
        if line.hasPrefix("+") { return Theme.positive }
        if line.hasPrefix("-") { return Color(red: 0.82, green: 0.18, blue: 0.18) }
        return Theme.inkSoft
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Theme.positive.opacity(0.08) }
        if line.hasPrefix("-") { return Color.red.opacity(0.06) }
        return .clear
    }
}
