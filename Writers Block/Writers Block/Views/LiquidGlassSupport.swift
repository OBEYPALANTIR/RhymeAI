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
        static let drawerHorizontalMargin: CGFloat = 36
        static let assistantColumnWidth: CGFloat = 380
        static let assistantReadableWidth: CGFloat = 420
        static let assistantSheetHandleArea: CGFloat = 72
        static let assistantSheetHandleWidth: CGFloat = 52
        static let assistantSheetHandleHeight: CGFloat = 4
        static let editorMaxWidth: CGFloat = 740
        static let editorBottomRest: CGFloat = 200
    }

    enum Motion {
        // Keep routine feedback brief; only a released drag needs a settling spring.
        static let feedbackDuration: TimeInterval = 0.16
        static let stateDuration: TimeInterval = 0.20
        static let presentationDuration: TimeInterval = 0.26
        static let settleDuration: TimeInterval = 0.420

        static let feedback: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: feedbackDuration)
        static let dismiss: Animation = feedback
        static let state: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: stateDuration)
        static let dialog: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: presentationDuration)
        static let presentation: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: presentationDuration)
        static let settle: Animation = .spring(response: settleDuration, dampingFraction: 0.80)

        // The recording control changes shape once to expose its timer and stop action.
        static let recording: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: presentationDuration)
    }
}

struct RhymeAIPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : RhymeAITokens.Motion.feedback, value: configuration.isPressed)
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
