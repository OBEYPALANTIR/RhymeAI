import SwiftUI

enum AppAppearanceStyle: String, CaseIterable, Hashable, Identifiable {
    case ink
    case paper
    case graphite

    static let storageKey = "appAppearanceStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ink:
            "Ink"
        case .paper:
            "Paper"
        case .graphite:
            "Graphite"
        }
    }

    var preferredColorScheme: ColorScheme {
        switch self {
        case .ink, .paper:
            .light
        case .graphite:
            .dark
        }
    }

    var usesDarkAnalysisPalette: Bool {
        self == .graphite
    }

    var analysisRhymeHexValues: [UInt32] {
        if usesDarkAnalysisPalette {
            return [
                0xFCA5A5, 0xFCD34D, 0x86EFAC, 0x7DD3FC,
                0xC4B5FD, 0xF9A8D4, 0xFDBA74, 0x67E8F9,
                0xA7F3D0, 0xE9D5FF, 0xFEF08A, 0xBEF264,
            ]
        }
        return [
            0xB91C1C, 0x92400E, 0x166534, 0x0369A1,
            0x6D28D9, 0xBE185D, 0x9A3412, 0x155E75,
            0x047857, 0x7E22CE, 0x854D0E, 0x3F6212,
        ]
    }

    var analysisSyllableHexValues: [UInt32] {
        if usesDarkAnalysisPalette {
            return [0x6EE7B7, 0x93C5FD, 0xD8B4FE, 0xFDA4AF]
        }
        return [0x047857, 0x0369A1, 0x7E22CE, 0xB91C1C]
    }

    var editorWordCountHexValue: UInt32 { analysisSyllableHexValues[0] }
    var editorSyllableCountHexValue: UInt32 { analysisSyllableHexValues[3] }

    var statusSuccessHexValue: UInt32 { usesDarkAnalysisPalette ? 0x6EE7B7 : 0x047857 }
    var statusWarningHexValue: UInt32 { usesDarkAnalysisPalette ? 0xFFB95B : 0x92400E }
    var statusErrorHexValue: UInt32 { usesDarkAnalysisPalette ? 0xFFB4AB : 0xB3261E }
    var statusRecordingHexValue: UInt32 { usesDarkAnalysisPalette ? 0xFF8A80 : 0xB3261E }

    var placeholderHexValue: UInt32 {
        switch self {
        case .ink:
            0x5E5E58
        case .paper:
            0x5D574E
        case .graphite:
            0xAAA49A
        }
    }

    /// On-state switch track. The action colour on the light appearances; on
    /// Graphite the cream action colour sat behind the white thumb at 1.1:1, so
    /// the track is the strong outline tone (4.5:1 to the thumb, 4.0:1 to the canvas).
    var switchTrackHexValue: UInt32 {
        switch self {
        case .ink:
            0x050505
        case .paper:
            0x302E2A
        case .graphite:
            0x7B766D
        }
    }

    /// Label of a disabled button: at least 3:1 on the canvas and on the
    /// raised fill a disabled button sits on, and plainly dimmer than secondary ink.
    var disabledInkHexValue: UInt32 {
        switch self {
        case .ink:
            0x7A7A74
        case .paper:
            0x756F64
        case .graphite:
            0x857F77
        }
    }

    var palette: AppAppearancePalette {
        switch self {
        case .ink:
            .ink
        case .paper:
            .paper
        case .graphite:
            .graphite
        }
    }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .ink
    }
}

struct AppAppearancePalette {
    let canvas: Color
    let surface: Color
    let raisedSurface: Color
    /// Raised rows and cards: a half step off the page.
    let surfaceLow: Color
    /// Floating cards and the drawer panel.
    let surfaceHigh: Color
    let primaryInk: Color
    let secondaryInk: Color
    let outline: Color
    let outlineStrong: Color
    let action: Color
    let onAction: Color
    let switchTrack: Color
    /// Label of a disabled button, drawn on the raised surface instead of the action fill.
    let disabledInk: Color
    let caret: Color
    let placeholder: Color
    let selectionTint: Color
    let scrim: Color
    let success: Color
    let warning: Color
    let error: Color
    let recording: Color
    /// Shadow tint: the ink on the light appearances; black on Graphite, where a cream shadow would read as a glow.
    let shadowInk: Color

    fileprivate static let ink = AppAppearancePalette(
        canvas: Color(hex: 0xFCFCF8),
        surface: Color(hex: 0xFCFCF8),
        raisedSurface: Color(hex: 0xE5E5DE),
        surfaceLow: Color(hex: 0xF7F7F2),
        surfaceHigh: Color(hex: 0xE5E5DE),
        primaryInk: Color(hex: 0x050505),
        secondaryInk: Color(hex: 0x4D4D48),
        outline: Color(hex: 0xB5B5AD),
        outlineStrong: Color(hex: 0x5E5E58),
        action: Color(hex: 0x050505),
        onAction: Color(hex: 0xFCFCF8),
        switchTrack: Color(hex: AppAppearanceStyle.ink.switchTrackHexValue),
        disabledInk: Color(hex: AppAppearanceStyle.ink.disabledInkHexValue),
        caret: Color(hex: 0x050505),
        placeholder: Color(hex: AppAppearanceStyle.ink.placeholderHexValue),
        selectionTint: Color(hex: 0xDADAD2),
        scrim: Color(hex: 0x050505).opacity(0.42),
        success: Color(hex: AppAppearanceStyle.ink.statusSuccessHexValue),
        warning: Color(hex: AppAppearanceStyle.ink.statusWarningHexValue),
        error: Color(hex: AppAppearanceStyle.ink.statusErrorHexValue),
        recording: Color(hex: AppAppearanceStyle.ink.statusRecordingHexValue),
        shadowInk: Color(hex: 0x050505)
    )

    fileprivate static let paper = AppAppearancePalette(
        canvas: Color(hex: 0xF3EEDF),
        surface: Color(hex: 0xF8F3E6),
        raisedSurface: Color(hex: 0xDDD4BF),
        surfaceLow: Color(hex: 0xEFE8D7),
        surfaceHigh: Color(hex: 0xDDD4BF),
        primaryInk: Color(hex: 0x302E2A),
        secondaryInk: Color(hex: 0x5D574E),
        outline: Color(hex: 0xB7AC94),
        outlineStrong: Color(hex: 0x696257),
        action: Color(hex: 0x302E2A),
        onAction: Color(hex: 0xFFF9EB),
        switchTrack: Color(hex: AppAppearanceStyle.paper.switchTrackHexValue),
        disabledInk: Color(hex: AppAppearanceStyle.paper.disabledInkHexValue),
        caret: Color(hex: 0x302E2A),
        placeholder: Color(hex: AppAppearanceStyle.paper.placeholderHexValue),
        selectionTint: Color(hex: 0xD8CDB4),
        scrim: Color(hex: 0x302E2A).opacity(0.42),
        success: Color(hex: AppAppearanceStyle.paper.statusSuccessHexValue),
        warning: Color(hex: AppAppearanceStyle.paper.statusWarningHexValue),
        error: Color(hex: AppAppearanceStyle.paper.statusErrorHexValue),
        recording: Color(hex: AppAppearanceStyle.paper.statusRecordingHexValue),
        shadowInk: Color(hex: 0x302E2A)
    )

    fileprivate static let graphite = AppAppearancePalette(
        canvas: Color(hex: 0x171716),
        surface: Color(hex: 0x1C1C1B),
        raisedSurface: Color(hex: 0x2B2B28),
        surfaceLow: Color(hex: 0x20201E),
        surfaceHigh: Color(hex: 0x2B2B28),
        primaryInk: Color(hex: 0xF6F2E8),
        secondaryInk: Color(hex: 0xC4BEB3),
        outline: Color(hex: 0x484843),
        outlineStrong: Color(hex: 0x7B766D),
        action: Color(hex: 0xF6F2E8),
        onAction: Color(hex: 0x171716),
        switchTrack: Color(hex: AppAppearanceStyle.graphite.switchTrackHexValue),
        disabledInk: Color(hex: AppAppearanceStyle.graphite.disabledInkHexValue),
        caret: Color(hex: 0xF6F2E8),
        placeholder: Color(hex: AppAppearanceStyle.graphite.placeholderHexValue),
        selectionTint: Color(hex: 0x41413D),
        scrim: Color.black.opacity(0.55),
        success: Color(hex: AppAppearanceStyle.graphite.statusSuccessHexValue),
        warning: Color(hex: AppAppearanceStyle.graphite.statusWarningHexValue),
        error: Color(hex: AppAppearanceStyle.graphite.statusErrorHexValue),
        recording: Color(hex: AppAppearanceStyle.graphite.statusRecordingHexValue),
        shadowInk: Color.black
    )
}

private struct AppAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppAppearanceStyle = .ink
}

private struct AppAppearanceBindingEnvironmentKey: EnvironmentKey {
    static let defaultValue: Binding<AppAppearanceStyle> = .constant(.ink)
}

extension EnvironmentValues {
    var appAppearanceStyle: AppAppearanceStyle {
        get { self[AppAppearanceEnvironmentKey.self] }
        set { self[AppAppearanceEnvironmentKey.self] = newValue }
    }

    var appAppearanceBinding: Binding<AppAppearanceStyle> {
        get { self[AppAppearanceBindingEnvironmentKey.self] }
        set { self[AppAppearanceBindingEnvironmentKey.self] = newValue }
    }
}

struct AppWritingBackground: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appAppearanceStyle) private var appearance

    private var textureEnabled: Bool {
        !reduceTransparency && colorSchemeContrast != .increased
    }

    var body: some View {
        ZStack {
            appearance.palette.canvas

            if textureEnabled {
                AppearanceTexture(appearance: appearance)
                    .equatable()
            }
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AppearanceTexture: View, Equatable {
    let appearance: AppAppearanceStyle

    var body: some View {
        let palette = appearance.palette

        ZStack {
            if appearance == .paper {
                CachedAppearanceTextureShape(appearance: appearance, layer: .paperRules)
                    .stroke(palette.primaryInk.opacity(0.055), lineWidth: 1)
                // A faint edge vignette, like light falling off a sheet.
                EllipticalGradient(
                    colors: [.clear, palette.primaryInk.opacity(0.02)],
                    startRadiusFraction: 0.35,
                    endRadiusFraction: 0.75
                )
            }
            CachedAppearanceTextureShape(appearance: appearance, layer: .grain)
                .stroke(grainColor(palette), lineWidth: grainLineWidth)
        }
    }

    /// Paper: warm fibre in the outline colour (the strong one: the light outline
    /// at 4.5% sat about 3 levels off the canvas, too faint to see). Ink: a finer,
    /// cooler tooth. Graphite: pencil grain.
    private func grainColor(_ palette: AppAppearancePalette) -> Color {
        switch appearance {
        case .ink: palette.primaryInk.opacity(0.03)
        case .paper: palette.outlineStrong.opacity(0.045)
        case .graphite: palette.primaryInk.opacity(0.04)
        }
    }

    private var grainLineWidth: CGFloat {
        switch appearance {
        case .ink: 0.5
        case .paper: 0.75
        case .graphite: 0.6
        }
    }
}

enum AppearanceTextureLayer: Hashable {
    case paperRules
    case grain
}

private struct CachedAppearanceTextureShape: Shape {
    let appearance: AppAppearanceStyle
    let layer: AppearanceTextureLayer

    func path(in rect: CGRect) -> Path {
        Path(AppearanceTexturePathCache.shared.path(for: appearance, layer: layer, in: rect))
    }
}

final class AppearanceTexturePathCache: @unchecked Sendable {
    static let shared = AppearanceTexturePathCache()

    private struct Key: Hashable {
        let appearance: AppAppearanceStyle
        let layer: AppearanceTextureLayer
        let xBits: UInt64
        let yBits: UInt64
        let widthBits: UInt64
        let heightBits: UInt64

        init(appearance: AppAppearanceStyle, layer: AppearanceTextureLayer, rect: CGRect) {
            self.appearance = appearance
            self.layer = layer
            xBits = Double(rect.origin.x).bitPattern
            yBits = Double(rect.origin.y).bitPattern
            widthBits = Double(rect.width).bitPattern
            heightBits = Double(rect.height).bitPattern
        }
    }

    private let lock = NSLock()
    private var paths: [Key: CGPath] = [:]
    private var generationCount = 0
    private static let capacity = 24

    func path(for appearance: AppAppearanceStyle, layer: AppearanceTextureLayer, in rect: CGRect) -> CGPath {
        let key = Key(appearance: appearance, layer: layer, rect: rect)

        lock.lock()
        defer { lock.unlock() }

        if let cached = paths[key] {
            return cached
        }

        if paths.count >= Self.capacity {
            paths.removeAll(keepingCapacity: true)
        }

        let path = Self.makePath(appearance: appearance, layer: layer, in: rect)
        paths[key] = path
        generationCount += 1
        return path
    }

    var generatedPathCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationCount
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        paths.removeAll(keepingCapacity: true)
        generationCount = 0
    }

    private static func makePath(appearance: AppAppearanceStyle, layer: AppearanceTextureLayer, in rect: CGRect) -> CGPath {
        switch layer {
        case .paperRules:
            paperRulesPath(in: rect)
        case .grain:
            grainPath(appearance: appearance, in: rect)
        }
    }

    private static func paperRulesPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        var y: CGFloat = 28

        while y < rect.height {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + y))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + y))
            y += 28
        }

        return path
    }

    /// Short diagonal marks, one per cell of a 16pt-row grid (22pt columns,
    /// 16pt on Ink), each nudged, sized and tilted by a hash of its cell so
    /// the grid never reads as a pattern. One path for the whole surface.
    static func grainPath(appearance: AppAppearanceStyle, in rect: CGRect) -> CGPath {
        let rowHeight: CGFloat = 16
        let columnWidth: CGFloat = appearance == .ink ? 16 : 22
        let lengths: ClosedRange<CGFloat> = switch appearance {
        case .ink: 1.2...2.4
        case .paper: 2.5...5.5
        case .graphite: 1.6...3.2
        }
        let path = CGMutablePath()
        var row = 0
        var y: CGFloat = 0

        while y < rect.height {
            var column = 0
            var x: CGFloat = 0
            while x < rect.width {
                let hash = grainHash(row, column)
                let unit = { (shift: UInt32) in CGFloat((hash >> shift) & 0xFF) / 255 }
                let start = CGPoint(x: rect.minX + x + unit(0) * columnWidth, y: rect.minY + y + unit(8) * rowHeight)
                let length = lengths.lowerBound + unit(16) * (lengths.upperBound - lengths.lowerBound)
                // Down-right diagonals, tilted ±15°.
                let angle = CGFloat.pi / 4 + (unit(24) - 0.5) * (CGFloat.pi / 6)
                path.move(to: start)
                path.addLine(to: CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length))
                column += 1
                x += columnWidth
            }
            row += 1
            y += rowHeight
        }

        return path
    }

    private static func grainHash(_ row: Int, _ column: Int) -> UInt32 {
        var value = UInt32(truncatingIfNeeded: row &* 73_856_093 ^ column &* 19_349_663)
        value ^= value >> 13
        value &*= 0x5BD1_E995
        value ^= value >> 15
        return value
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
