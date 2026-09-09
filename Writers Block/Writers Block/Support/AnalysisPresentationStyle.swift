import SwiftUI

enum AnalysisPresentationStyle: String, CaseIterable, Hashable, Identifiable {
    case color
    case inkMarks

    static let storageKey = "analysisPresentationStyle"
    var id: String { rawValue }
    var displayName: String { self == .color ? "Color" : "Ink Marks" }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .color
    }
}

enum InkUnderlinePattern: Int, CaseIterable, Hashable {
    case solid, dashed, dotted, dashDot
}

func analysisInkPattern(for familyKey: String) -> InkUnderlinePattern {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in familyKey.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return InkUnderlinePattern(rawValue: Int(hash % 4)) ?? .solid
}

func analysisFontWeight(syllableCount: Int) -> Font.Weight {
    switch syllableCount {
    case ...1: .regular
    case 2: .medium
    case 3: .semibold
    default: .bold
    }
}

func analysisFontWeight(syllableCount: Int, syllableGuideEnabled: Bool) -> Font.Weight? {
    guard syllableGuideEnabled else { return nil }
    return analysisFontWeight(syllableCount: syllableCount)
}

private struct AnalysisPresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue: AnalysisPresentationStyle = .color
}

private struct AnalysisPresentationBindingEnvironmentKey: EnvironmentKey {
    static let defaultValue: Binding<AnalysisPresentationStyle> = .constant(.color)
}

extension EnvironmentValues {
    var analysisPresentationStyle: AnalysisPresentationStyle {
        get { self[AnalysisPresentationEnvironmentKey.self] }
        set { self[AnalysisPresentationEnvironmentKey.self] = newValue }
    }

    var analysisPresentationBinding: Binding<AnalysisPresentationStyle> {
        get { self[AnalysisPresentationBindingEnvironmentKey.self] }
        set { self[AnalysisPresentationBindingEnvironmentKey.self] = newValue }
    }
}
