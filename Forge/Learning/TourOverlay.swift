import SwiftUI

/// The guided-tour overlay: dims the screen, cuts a spotlight around the current
/// step's element, and shows a narration tooltip next to it. Modal — taps are
/// swallowed so the user follows "Næste"; the final step hands back control.
struct TourOverlay: View {
    @Environment(AppModel.self) private var model
    let resolved: [TourStop: CGRect]
    let size: CGSize
    @State private var tipSize = CGSize(width: 340, height: 220)

    private var step: TourStep { Tour.steps[min(model.tourIndex, Tour.steps.count - 1)] }
    private var hole: CGRect? { resolved[step.stop].map { $0.insetBy(dx: -8, dy: -8) } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpotlightShape(hole: hole, cornerRadius: 12)
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }   // modal: swallow background taps

            if let hole {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
            }

            TourTooltip(step: step, index: model.tourIndex, total: Tour.steps.count,
                        onNext: { model.tourNext() }, onSkip: { model.endTour() })
                .frame(width: 340)
                .background(GeometryReader { g in
                    Color.clear.preference(key: TipSizeKey.self, value: g.size)
                })
                .onPreferenceChange(TipSizeKey.self) { tipSize = $0 }
                .position(tooltipCenter())
        }
        .animation(.smooth(duration: 0.25), value: model.tourIndex)
    }

    private func tooltipCenter() -> CGPoint {
        let h = tipSize.height
        guard let r = hole else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let cx = min(max(r.midX, 170 + 16), size.width - 170 - 16)
        let below = r.maxY + 14 + h / 2
        let above = r.minY - 14 - h / 2
        let cy = (below + h / 2 < size.height - 12) ? below : max(h / 2 + 12, above)
        return CGPoint(x: cx, y: cy)
    }
}

/// Full-screen rect with a rounded-rect hole, drawn via even-odd fill.
struct SpotlightShape: Shape {
    let hole: CGRect?
    let cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        if let hole {
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        }
        return p
    }
}

private struct TipSizeKey: PreferenceKey {
    static let defaultValue = CGSize(width: 340, height: 220)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct TourTooltip: View {
    let step: TourStep
    let index: Int
    let total: Int
    var onNext: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: step.icon)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(step.title)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text("\(index + 1)/\(total)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkFaint)
            }
            Text(step.body)
                .font(.system(size: 12.5)).foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if !step.terms.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(step.terms) { term in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(term.term)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.ink)
                            Text(term.explanation)
                                .font(.system(size: 11.5)).foregroundStyle(Theme.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
            HStack(spacing: 8) {
                Button("Spring over") { onSkip() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(0..<total, id: \.self) { i in
                        Circle().fill(i == index ? Theme.accent : Theme.border).frame(width: 5, height: 5)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onNext) {
                    Text(index == total - 1 ? "Kom i gang" : "Næste")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }
}
