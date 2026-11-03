import SwiftUI

/// Visual language: quiet and uncluttered. Serif headings, light rounded numerals,
/// Liquid Glass surfaces, and colour used only where it carries meaning.
enum Theme {
    static let cornerRadius: CGFloat = 26
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
        } else if let tint {
            content.background(tint, in: shape)
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

/// Lets nearby glass shapes blend together on iOS 26 and later.
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
    func card(padding: CGFloat = 16, interactive: Bool = false) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous), interactive: interactive)
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

/// The same heading on every tab: a small label above a serif title, with an optional button.
struct PageHeader<Trailing: View>: View {
    var eyebrow: String?
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(Theme.eyebrow)
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(title)
                    .font(Theme.title(34))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.top, 6)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// A round glass button. `prominent` tints it with the accent colour.
struct GlassCircleButton: View {
    let systemImage: String
    var prominent = false
    var size: CGFloat = 44
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(width: size, height: size)
                .liquidGlass(Circle(), tint: prominent ? Palette.accent : nil, interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

/// A gentle wash of colour behind everything, which the glass picks up.
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

/// A short pop-up: ✕ on the left, the title, ✓ on the right, then the fields.
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
        VStack(spacing: 20) {
            HStack {
                GlassCircleButton(systemImage: "xmark", label: "Cancel") { dismiss() }
                Spacer()
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Spacer()
                GlassCircleButton(systemImage: "checkmark", prominent: true, label: "Save", action: onSave)
                    .disabled(!canSave || saving)
                    .opacity(canSave && !saving ? 1 : 0.4)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
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
