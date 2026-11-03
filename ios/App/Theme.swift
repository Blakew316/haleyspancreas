import SwiftUI

/// Visual language: quiet, warm and uncluttered. Serif headings, light rounded numerals,
/// glass cards, and colour used only where it carries meaning.
enum Theme {
    static let cornerRadius: CGFloat = 26
    static let spacing: CGFloat = 16

    static func title(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .light, design: .rounded) }
    static let eyebrow = Font.system(.caption, design: .rounded).weight(.semibold)
}

/// A soft glass card. Uses Liquid Glass on iOS 26 and later, frosted material before that.
struct Card: ViewModifier {
    var padding: CGFloat = 18
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
        }
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(Card(padding: padding)) }
}

/// Small uppercase label above a value.
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.eyebrow)
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

/// A gentle wash of the current range colour behind everything.
struct AmbientBackground: View {
    let color: Color
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RadialGradient(colors: [color.opacity(0.32), .clear], center: .topLeading, startRadius: 20, endRadius: 520)
            RadialGradient(colors: [Palette.accent.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 480)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: color)
    }
}

extension Date {
    var greeting: String {
        switch Calendar.current.component(.hour, from: self) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }
}
