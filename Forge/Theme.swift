import SwiftUI
import AppKit

/// "Midnat" design system — a dark, professional, IDE-like palette (the default)
/// with a clean light variant. Every token is a DYNAMIC color that resolves by
/// the view's effective appearance, which the app drives from
/// `Preferences.appearance` via `.preferredColorScheme`. The violet accent is
/// shared across both modes for brand consistency.
enum Theme {
    static let canvas      = dyn(light: 0xFFFFFF, dark: 0x0F1117)   // app background
    static let sidebar     = dyn(light: 0xFAFAFB, dark: 0x0C0E14)   // rails / panels
    static let surface     = dyn(light: 0xFFFFFF, dark: 0x161922)   // cards / inputs
    static let border      = dyn(light: 0xE6E6EA, dark: 0x20242F)
    static let borderStrong = dyn(light: 0xC9C9D0, dark: 0x2E3440)
    static let ink         = dyn(light: 0x14151A, dark: 0xE6E8EE)   // primary text
    static let inkSoft     = dyn(light: 0x6B6B76, dark: 0x9AA0AE)   // secondary text
    static let inkFaint    = dyn(light: 0x9A9AA4, dark: 0x6B7180)   // tertiary text
    static let accent      = dyn(light: 0x6F5CFF, dark: 0x7C6CFF)   // violet
    static let onAccent    = Color.white
    static let fill        = dyn(light: 0xF4F4F7, dark: 0x1A1F2B)
    static let fillHover   = dyn(light: 0xEBEBEF, dark: 0x232938)
    static let positive    = dyn(light: 0x1FA463, dark: 0x3FCF8E)
    static let warning     = dyn(light: 0xC9810F, dark: 0xE0A33A)   // amber — runtime-error affordance

    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 16

    /// C17: one shared motion language so animations feel consistent app-wide.
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.14)                       // taps / hovers
        static let smooth = Animation.smooth(duration: 0.28)                       // layout / panels
        static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.82) // entrances
    }

    static func wordmark(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    /// A color that resolves per the view's effective appearance (light/dark).
    static func dyn(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
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
            .scaleEffect(configuration.isPressed ? 0.92 : 1)   // C17: press feedback
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// C17: a subtle press affordance (scale + dim) for primary / `.plain` buttons,
/// using the shared motion language. Apply where a tap should feel responsive.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
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
