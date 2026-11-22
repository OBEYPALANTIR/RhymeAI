import SwiftUI

struct AppearanceSettingsSection: View {
    @Environment(\.appAppearanceBinding) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            #if os(macOS)
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.wrappedValue.palette.secondaryInk)
                .textCase(.uppercase)
            #else
            SettingsSectionTitle("Appearance", systemImage: "circle.lefthalf.filled")
            #endif

            RhymeSegmentedControl(
                options: AppAppearanceStyle.allCases,
                selection: appearance,
                accessibilityIdentifier: "appearancePicker",
                label: "Appearance",
                title: \.displayName
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: SettingsMetrics.groupRadius)
    }
}

#Preview {
    AppearanceSettingsSection()
        .padding()
        .environment(\.appAppearanceStyle, .paper)
        .environment(\.appAppearanceBinding, .constant(.paper))
}
