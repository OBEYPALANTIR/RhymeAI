import SwiftUI

struct AppearanceSettingsSection: View {
    @Environment(\.appAppearanceBinding) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Picker("Appearance", selection: appearance) {
                ForEach(AppAppearanceStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearancePicker")
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
