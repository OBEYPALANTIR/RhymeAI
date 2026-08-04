import SwiftUI
import Testing
@testable import Writers_Block

struct AppAppearanceTests {
    @Test
    func rawValuesRoundTrip() {
        let expectedValues: [(String, AppAppearanceStyle)] = [
            ("ink", .ink),
            ("paper", .paper),
            ("graphite", .graphite),
        ]

        for (rawValue, style) in expectedValues {
            #expect(style.rawValue == rawValue)
            #expect(AppAppearanceStyle(rawValue: rawValue) == style)
        }
    }

    @Test
    func storageKeyAndDisplayNamesAreStable() {
        #expect(AppAppearanceStyle.storageKey == "appAppearanceStyle")
        #expect(AppAppearanceStyle.allCases.map(\.displayName) == ["Ink", "Paper", "Graphite"])
    }

    @Test
    func unknownValuesFallBackToInk() {
        #expect(AppAppearanceStyle.resolve(nil) == .ink)
        #expect(AppAppearanceStyle.resolve("neon") == .ink)
    }

    @Test
    func graphiteIsTheOnlyDarkAppearance() {
        #expect(AppAppearanceStyle.ink.preferredColorScheme == .light)
        #expect(AppAppearanceStyle.paper.preferredColorScheme == .light)
        #expect(AppAppearanceStyle.graphite.preferredColorScheme == .dark)
    }

    @Test
    func graphiteIsTheOnlyDarkAnalysisPalette() {
        #expect(!AppAppearanceStyle.ink.usesDarkAnalysisPalette)
        #expect(!AppAppearanceStyle.paper.usesDarkAnalysisPalette)
        #expect(AppAppearanceStyle.graphite.usesDarkAnalysisPalette)
    }

    @Test
    func graphiteTextureGeometryIsCachedByResolvedSize() {
        let cache = AppearanceTexturePathCache()
        let phoneSize = CGRect(x: 0, y: 0, width: 393, height: 852)

        _ = cache.path(for: .graphite, layer: .graphiteGrain, in: phoneSize)
        _ = cache.path(for: .graphite, layer: .graphiteGrain, in: phoneSize)
        #expect(cache.generatedPathCount == 1)

        _ = cache.path(
            for: .graphite,
            layer: .graphiteGrain,
            in: CGRect(x: 0, y: 0, width: 852, height: 393)
        )
        #expect(cache.generatedPathCount == 2)
    }

    @Test
    func lightRhymePaletteMatchesApprovedContrastSafeTokens() {
        #expect(AppAppearanceStyle.ink.analysisRhymeHexValues == [
            0xB91C1C,
            0x92400E,
            0x166534,
            0x0369A1,
            0x6D28D9,
            0xBE185D,
            0x9A3412,
            0x155E75,
            0x047857,
            0x7E22CE,
            0x854D0E,
            0x3F6212,
        ])
        #expect(AppAppearanceStyle.paper.analysisRhymeHexValues == AppAppearanceStyle.ink.analysisRhymeHexValues)
    }

    @Test
    func statusColorsAdaptToTheResolvedAppearance() {
        #expect(AppAppearanceStyle.ink.statusWarningHexValue == 0x92400E)
        #expect(AppAppearanceStyle.paper.statusWarningHexValue == 0x92400E)
        #expect(AppAppearanceStyle.graphite.statusWarningHexValue == 0xFFB95B)
        #expect(AppAppearanceStyle.ink.statusSuccessHexValue == 0x047857)
        #expect(AppAppearanceStyle.graphite.statusSuccessHexValue == 0x6EE7B7)
        #expect(AppAppearanceStyle.ink.statusErrorHexValue == 0xB3261E)
        #expect(AppAppearanceStyle.graphite.statusErrorHexValue == 0xFFB4AB)
    }

    @Test
    func placeholderColorsRemainReadableOnInteractiveSurfaces() {
        #expect(AppAppearanceStyle.ink.placeholderHexValue == 0x5E5E58)
        #expect(AppAppearanceStyle.paper.placeholderHexValue == 0x5D574E)
        #expect(AppAppearanceStyle.graphite.placeholderHexValue == 0xAAA49A)
    }
}
