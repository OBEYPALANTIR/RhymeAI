import SwiftUI

struct AppearanceSettingsSection: View {
    @Environment(\.appAppearanceBinding) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.wrappedValue.palette.secondaryInk)
                .textCase(.uppercase)

            RhymeSegmentedControl(
                options: AppAppearanceStyle.allCases,
                selection: appearance,
                accessibilityIdentifier: "appearancePicker",
                label: "Appearance",
                title: \.displayName
            )
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl)
    }
}

#Preview {
    AppearanceSettingsSection()
        .padding()
        .environment(\.appAppearanceStyle, .paper)
        .environment(\.appAppearanceBinding, .constant(.paper))
}
