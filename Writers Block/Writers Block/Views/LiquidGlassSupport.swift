import SwiftUI

enum RhymeAITokens {
    static let phi: CGFloat = 1.618
    static let inversePhi: CGFloat = 0.618
    static let phiSquared: CGFloat = 2.618

    enum Spacing {
        static let hairline: CGFloat = 1
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 20
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 52
    }

    /// Golden-ratio spacing ladder (8·13·21·34·55, each step ≈ ×φ), one meaning
    /// per step. Android mirror: `DesignTokens.Rhythm`.
    enum Rhythm {
        /// Icon to label, badge padding.
        static let tight: CGFloat = 8
        /// Heading to caption, label to its control, text to badge, field inset, the two scribble lines.
        static let related: CGFloat = 13
        /// Card padding, gap between cards and sub-groups, section heading to first card.
        static let standard: CGFloat = 21
        /// Between panel sections, and the panel's edge padding.
        static let section: CGFloat = 34
        /// The primary action's height.
        static let primary: CGFloat = 55
    }

    enum Touch {
        static let minimum: CGFloat = 44
        static let comfortable: CGFloat = 56
        static let prominent: CGFloat = 82
    }

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 32
        static let pill: CGFloat = 52
    }

    enum Layout {
        static let drawerMinWidth: CGFloat = 300
        static let drawerMaxWidth: CGFloat = 360
        static let assistantColumnWidth: CGFloat = 380
        static let assistantReadableWidth: CGFloat = 420
        static let assistantSheetHandleArea: CGFloat = Touch.minimum
        static let assistantSheetHandleWidth: CGFloat = 52
        static let assistantSheetHandleHeight: CGFloat = 4
        static let editorMaxWidth: CGFloat = 740
        static let editorBottomRest: CGFloat = 200

        /// Regular-width side columns (the inline assistant, the songs drawer)
        /// take the minor golden share (38.2%) of the window, never under 380pt.
        static func sideColumnWidth(for windowWidth: CGFloat) -> CGFloat {
            max(assistantColumnWidth, (windowWidth * (1 - RhymeAITokens.inversePhi)).rounded())
        }

        /// The narrowest window that keeps the editor at least as wide as the
        /// 380pt side column beside it (760pt). Narrower regular-width windows
        /// (Split View, Stage Manager) use the single-column editor and sheet.
        static let sideColumnMinimumWindowWidth: CGFloat = assistantColumnWidth * 2

        static func fitsSideColumn(windowWidth: CGFloat) -> Bool {
            windowWidth >= sideColumnMinimumWindowWidth
        }
    }

    enum Motion {
        // Golden-ratio duration ladder: 0.16 ×φ ≈0.26 ×φ ≈0.42 (φ=1.618). Utilitarian tiers ≤0.50s.
        static let feedbackDuration: TimeInterval = 0.16
        static let stateDuration: TimeInterval = 0.260
        static let presentationDuration: TimeInterval = 0.26
        static let settleDuration: TimeInterval = 0.420

        static let feedback: Animation = .easeInOut(duration: feedbackDuration)
        static let dismiss: Animation = .easeInOut(duration: feedbackDuration)
        static let state: Animation = .easeInOut(duration: stateDuration)
        static let dialog: Animation = .easeInOut(duration: stateDuration)
        static let presentation: Animation = .spring(response: presentationDuration, dampingFraction: 0.88)
        static let settle: Animation = .spring(response: settleDuration, dampingFraction: 0.80)

        /// Expressive spring for the mic↔pill choreography and the UnBlock FAB
        /// fall-down — a ~0.4s glide with a subtle settle (no hard snap). Drives the
        /// pill stretch, glyph crossfade, and FAB fall on one clock.
        /// Android equivalent: `DesignTokens.Motion.expressiveSpring()`
        /// (dampingRatio 0.76, stiffness 247 ≈ (2π / 0.40)²).
        static let expressive: Animation = .spring(response: 0.40, dampingFraction: 0.76)
        static let recording: Animation = expressive
    }
}

struct RhymeAIPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reports press begin and end, including a press that ends outside the control.
    var onPressingChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A custom style only hit-tests what the label draws, so a 44pt
            // frame around a glyph or a line of text would otherwise leave
            // just the ink tappable.
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : RhymeAITokens.Motion.feedback, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressingChanged?(isPressed)
            }
    }
}

extension ButtonStyle where Self == RhymeAIPressButtonStyle {
    static var rhymePress: RhymeAIPressButtonStyle { RhymeAIPressButtonStyle() }
}

private struct GatedAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_, value:)` that respects the OS reduce-motion setting.
    func rhymeAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(GatedAnimationModifier(animation: animation, value: value))
    }
}

/// `withAnimation` wrapper that honours reduce-motion. Pass the environment value from the call site.
func withRhymeAnimation<Result>(_ animation: Animation?, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    if reduceMotion {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return try withTransaction(transaction, body)
    }
    return try withAnimation(animation, body)
}


private struct LiquidGlassSurfaceModifier: ViewModifier {
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let fallbackOpacity: Double

    func body(content: Content) -> some View {
        let palette = appearance.palette
        let border = colorSchemeContrast == .increased || interactive
            ? palette.outlineStrong
            : palette.outline
        let surface = interactive ? palette.raisedSurface : palette.surface

        content
            .background(
                surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                if let tint {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(fallbackOpacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}

private struct AppearanceActionSurfaceModifier: ViewModifier {
    @Environment(\.appAppearanceStyle) private var appearance

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .foregroundStyle(appearance.palette.onAction)
            .background(
                appearance.palette.action,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

extension View {
    func liquidGlassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackOpacity: Double = 0.05
    ) -> some View {
        modifier(
            LiquidGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                fallbackOpacity: fallbackOpacity
            )
        )
    }

    func appearanceActionSurface(cornerRadius: CGFloat) -> some View {
        modifier(AppearanceActionSurfaceModifier(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func liquidGlassGroup(spacing: CGFloat = 16) -> some View {
        self
    }
}
