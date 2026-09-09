import CoreGraphics

enum RewriteRippleMotion {
    static let loopDuration: CFTimeInterval = 1.2
    static let stableProgress: CGFloat = 0.72
    static let loadingSelectionFillOpacity: CGFloat = 0.18

    static func advancedProgress(from progress: CGFloat, elapsed: CFTimeInterval) -> CGFloat {
        (progress + CGFloat(max(0, elapsed) / loopDuration))
            .truncatingRemainder(dividingBy: 1)
    }

    static func phase(progress: CGFloat) -> CGFloat {
        let normalized = min(max(progress, 0), 1).truncatingRemainder(dividingBy: 1)
        return normalized * 2 * .pi
    }

    static func verticalOffset(
        fraction: CGFloat,
        progress: CGFloat,
        amplitude: CGFloat,
        phaseOffset: CGFloat
    ) -> CGFloat {
        let angle = min(max(fraction, 0), 1) * 4 * .pi
            + phase(progress: progress)
            + phaseOffset
        return sin(angle) * amplitude
    }
}
