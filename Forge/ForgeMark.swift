import SwiftUI

/// The Forge anvil mark — the same silhouette as the app icon, as a vector Shape
/// so it can be tinted and sized anywhere in the UI. Authored in a 1024×1024
/// design space (anvil bounding box ≈ x[168,724] y[388,660]); `path(in:)` scales
/// that box to fill the given rect while preserving aspect.
struct ForgeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let bx: CGFloat = 168, by: CGFloat = 388
        let bw: CGFloat = 724 - 168, bh: CGFloat = 660 - 388
        let scale = min(rect.width / bw, rect.height / bh)
        let ox = rect.midX - bw * scale / 2 - bx * scale
        let oy = rect.midY - bh * scale / 2 - by * scale
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }

        var path = Path()
        path.move(to: p(168, 440))
        path.addLine(to: p(320, 388))
        path.addLine(to: p(708, 388))
        path.addQuadCurve(to: p(724, 404), control: p(724, 388))
        path.addLine(to: p(724, 484))
        path.addQuadCurve(to: p(708, 500), control: p(724, 500))
        path.addLine(to: p(584, 500))
        path.addLine(to: p(560, 600))
        path.addLine(to: p(692, 600))
        path.addQuadCurve(to: p(700, 608), control: p(700, 600))
        path.addLine(to: p(700, 652))
        path.addQuadCurve(to: p(692, 660), control: p(700, 660))
        path.addLine(to: p(332, 660))
        path.addQuadCurve(to: p(324, 652), control: p(324, 660))
        path.addLine(to: p(324, 608))
        path.addQuadCurve(to: p(332, 600), control: p(324, 600))
        path.addLine(to: p(464, 600))
        path.addLine(to: p(440, 500))
        path.addLine(to: p(320, 500))
        path.closeSubpath()
        return path
    }
}

/// App-icon-style badge: the anvil on the brand tile, matching the dock icon.
/// Used wherever the wordmark appears.
struct ForgeBadge: View {
    var size: CGFloat = 22
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2265, style: .continuous)
            .fill(Theme.canvas)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2265, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .overlay(ForgeMark().fill(Theme.accent).frame(width: size * 0.66, height: size * 0.66))
            .frame(width: size, height: size)
    }
}
