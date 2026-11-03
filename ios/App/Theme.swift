import SwiftUI

/// Visual language: quiet and uncluttered. Serif headings, light rounded numerals,
/// Liquid Glass surfaces, and colour used only where it carries meaning.
enum Theme {
    static let cornerRadius: CGFloat = 28
    static let spacing: CGFloat = 14

    static func title(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .light, design: .rounded) }
    static let eyebrow = Font.system(.caption, design: .rounded).weight(.semibold)
}

/// Liquid Glass on iOS 26 and later; frosted material on older versions.
struct LiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Lets nearby glass shapes blend and morph together on iOS 26 and later.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = Theme.spacing
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
    }

    /// A rounded glass card.
    func card(padding: CGFloat = 18, interactive: Bool = false) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous), interactive: interactive)
    }

    /// Glass button style on iOS 26 and later, bordered before.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// The tab bar shrinks while scrolling down, as in Apple's own apps (iOS 26 and later).
    @ViewBuilder
    func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

/// Small uppercase label above a value.
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.eyebrow)
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// A gentle wash of the current range colour behind everything, which the glass picks up.
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

/// A partial-height sheet with a title, a close button and a checkmark to save.
/// On iOS 26 and later, partial-height sheets are Liquid Glass automatically.
struct EntrySheet<Content: View>: View {
    let title: String
    var height: CGFloat = 300
    let canSave: Bool
    let saving: Bool
    let onSave: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onSave) {
                            if saving { ProgressView() } else { Image(systemName: "checkmark") }
                        }
                        .glassButton(prominent: true)
                        .tint(Palette.accent)
                        .disabled(!canSave || saving)
                        .accessibilityLabel("Save")
                    }
                }
        }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
    }
}

/// A soft rounded input field used inside sheets (plain fill, since glass shouldn't sit on glass).
struct FieldBackground: ViewModifier {
    var height: CGFloat = 56
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
