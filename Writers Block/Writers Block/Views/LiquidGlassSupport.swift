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
        static let feedbackDuration: TimeInterval = 0.180
        static let stateDuration: TimeInterval = 0.260
        static let presentationDuration: TimeInterval = 0.340
        static let settleDuration: TimeInterval = 0.420

        static let feedback: Animation = .easeInOut(duration: feedbackDuration)
        static let dismiss: Animation = .easeInOut(duration: feedbackDuration)
        static let state: Animation = .easeInOut(duration: stateDuration)
        static let dialog: Animation = .easeInOut(duration: stateDuration)
        static let presentation: Animation = .spring(response: presentationDuration, dampingFraction: 0.88)
        static let settle: Animation = .spring(response: settleDuration, dampingFraction: 0.72)
    }
}

struct RhymeAIPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
        return try body()
    }
    return try withAnimation(animation, body)
}


private struct LiquidGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let fallbackOpacity: Double

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .tint(tint)
                        .interactive(interactive),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            if cornerRadius == 0 {
                content
                    .background(.ultraThinMaterial)
                    .background((tint ?? Color.white).opacity(fallbackOpacity))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .background(
                        (tint ?? Color.white).opacity(fallbackOpacity),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    )
            }
        }
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

    @ViewBuilder
    func liquidGlassGroup(spacing: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }
}
