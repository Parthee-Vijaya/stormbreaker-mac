import SwiftUI

/// Lovable-style light design system: white canvas, black accents, subtle gray
/// borders, generous whitespace. All colors are EXPLICIT (never .primary/
/// .secondary) and the app forces light mode, so text is always visible
/// regardless of the system appearance.
enum Theme {
    static let canvas = Color.white
    static let sidebar = Color(white: 0.985)
    static let surface = Color.white
    static let border = Color(white: 0.90)
    static let borderStrong = Color(white: 0.78)
    static let ink = Color(white: 0.08)        // primary text
    static let inkSoft = Color(white: 0.42)     // secondary text
    static let inkFaint = Color(white: 0.62)    // tertiary text
    static let accent = Color.black
    static let onAccent = Color.white
    static let fill = Color(white: 0.965)
    static let fillHover = Color(white: 0.93)
    static let positive = Color(red: 0.16, green: 0.72, blue: 0.45)
    static let warning = Color(red: 0.85, green: 0.52, blue: 0.10)   // amber — runtime-error affordance

    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 16

    static func wordmark(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.inkSoft)
            .frame(width: 30, height: 28)
            .background(configuration.isPressed ? Theme.fillHover : Theme.fill,
                        in: RoundedRectangle(cornerRadius: Theme.radiusS))
            .contentShape(Rectangle())
    }
}

/// Lightweight flow layout so chips wrap onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
