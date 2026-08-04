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
    let primaryInk: Color
    let secondaryInk: Color
    let outline: Color
    let outlineStrong: Color
    let action: Color
    let onAction: Color
    let caret: Color
    let placeholder: Color
    let selectionTint: Color
    let scrim: Color
    let success: Color
    let warning: Color
    let error: Color
    let recording: Color

    fileprivate static let ink = AppAppearancePalette(
        canvas: Color(hex: 0xFCFCF8),
        surface: Color(hex: 0xFCFCF8),
        raisedSurface: Color(hex: 0xE5E5DE),
        primaryInk: Color(hex: 0x050505),
        secondaryInk: Color(hex: 0x4D4D48),
        outline: Color(hex: 0xB5B5AD),
        outlineStrong: Color(hex: 0x5E5E58),
        action: Color(hex: 0x050505),
        onAction: Color(hex: 0xFCFCF8),
        caret: Color(hex: 0x050505),
        placeholder: Color(hex: AppAppearanceStyle.ink.placeholderHexValue),
        selectionTint: Color(hex: 0xDADAD2),
        scrim: Color(hex: 0x050505).opacity(0.42),
        success: Color(hex: AppAppearanceStyle.ink.statusSuccessHexValue),
        warning: Color(hex: AppAppearanceStyle.ink.statusWarningHexValue),
        error: Color(hex: AppAppearanceStyle.ink.statusErrorHexValue),
        recording: Color(hex: AppAppearanceStyle.ink.statusRecordingHexValue)
    )

    fileprivate static let paper = AppAppearancePalette(
        canvas: Color(hex: 0xF3EEDF),
        surface: Color(hex: 0xF8F3E6),
        raisedSurface: Color(hex: 0xDDD4BF),
        primaryInk: Color(hex: 0x302E2A),
        secondaryInk: Color(hex: 0x5D574E),
        outline: Color(hex: 0xB7AC94),
        outlineStrong: Color(hex: 0x696257),
        action: Color(hex: 0x302E2A),
        onAction: Color(hex: 0xFFF9EB),
        caret: Color(hex: 0x302E2A),
        placeholder: Color(hex: AppAppearanceStyle.paper.placeholderHexValue),
        selectionTint: Color(hex: 0xD8CDB4),
        scrim: Color(hex: 0x302E2A).opacity(0.42),
        success: Color(hex: AppAppearanceStyle.paper.statusSuccessHexValue),
        warning: Color(hex: AppAppearanceStyle.paper.statusWarningHexValue),
        error: Color(hex: AppAppearanceStyle.paper.statusErrorHexValue),
        recording: Color(hex: AppAppearanceStyle.paper.statusRecordingHexValue)
    )

    fileprivate static let graphite = AppAppearancePalette(
        canvas: Color(hex: 0x171716),
        surface: Color(hex: 0x1C1C1B),
        raisedSurface: Color(hex: 0x2B2B28),
        primaryInk: Color(hex: 0xF6F2E8),
        secondaryInk: Color(hex: 0xC4BEB3),
        outline: Color(hex: 0x484843),
        outlineStrong: Color(hex: 0x7B766D),
        action: Color(hex: 0xF6F2E8),
        onAction: Color(hex: 0x171716),
        caret: Color(hex: 0xF6F2E8),
        placeholder: Color(hex: AppAppearanceStyle.graphite.placeholderHexValue),
        selectionTint: Color(hex: 0x41413D),
        scrim: Color.black.opacity(0.55),
        success: Color(hex: AppAppearanceStyle.graphite.statusSuccessHexValue),
        warning: Color(hex: AppAppearanceStyle.graphite.statusWarningHexValue),
        error: Color(hex: AppAppearanceStyle.graphite.statusErrorHexValue),
        recording: Color(hex: AppAppearanceStyle.graphite.statusRecordingHexValue)
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

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .ink:
            EmptyView()
        case .paper:
            ZStack {
                CachedAppearanceTextureShape(appearance: appearance, layer: .paperRules)
                    .stroke(appearance.palette.primaryInk.opacity(0.055), lineWidth: 1)
                CachedAppearanceTextureShape(appearance: appearance, layer: .paperFibers)
                    .stroke(appearance.palette.primaryInk.opacity(0.024), lineWidth: 0.5)
            }
        case .graphite:
            CachedAppearanceTextureShape(appearance: appearance, layer: .graphiteGrain)
                .stroke(appearance.palette.primaryInk.opacity(0.018), lineWidth: 0.75)
        }
    }
}

enum AppearanceTextureLayer: Hashable {
    case paperRules
    case paperFibers
    case graphiteGrain
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

        let path = Self.makePath(layer: layer, in: rect)
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

    private static func makePath(layer: AppearanceTextureLayer, in rect: CGRect) -> CGPath {
        switch layer {
        case .paperRules:
            paperRulesPath(in: rect)
        case .paperFibers:
            paperFibersPath(in: rect)
        case .graphiteGrain:
            graphiteGrainPath(in: rect)
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

    private static func paperFibersPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        var row = 0
        var y: CGFloat = 13

        while y < rect.height {
            var x = CGFloat(11 + (row % 4) * 13)
            while x < rect.width {
                path.move(to: CGPoint(x: rect.minX + x, y: rect.minY + y))
                path.addLine(to: CGPoint(x: rect.minX + x + 0.7, y: rect.minY + y + 5))
                x += 54
            }
            row += 1
            y += 38
        }

        return path
    }

    private static func graphiteGrainPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        var row = 0
        var y: CGFloat = 8

        while y < rect.height {
            var x = CGFloat(6 + (row % 3) * 5)
            while x < rect.width {
                path.move(to: CGPoint(x: rect.minX + x, y: rect.minY + y))
                path.addLine(to: CGPoint(x: rect.minX + x + 0.8, y: rect.minY + y + 0.28))
                x += 22
            }
            row += 1
            y += 16
        }

        return path
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
