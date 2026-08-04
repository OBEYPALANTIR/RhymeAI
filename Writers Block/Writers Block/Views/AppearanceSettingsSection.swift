import SwiftUI

struct AppearanceSettingsSection: View {
    @Environment(\.appAppearanceBinding) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            RhymeSegmentedControl(
                options: AppAppearanceStyle.allCases,
                selection: appearance,
                accessibilityIdentifier: "appearancePicker",
                title: \.displayName
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    previewCards
                }

                VStack(spacing: RhymeAITokens.Spacing.xs) {
                    previewCards
                }
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl)
    }

    @ViewBuilder
    private var previewCards: some View {
        ForEach(AppAppearanceStyle.allCases) { style in
            AppearancePreviewCard(style: style, selected: appearance.wrappedValue == style)
        }
    }
}

private struct AppearancePreviewCard: View {
    @Environment(\.appAppearanceStyle) private var activeAppearance

    let style: AppAppearanceStyle
    let selected: Bool

    private var palette: AppAppearancePalette { style.palette }
    private var activePalette: AppAppearancePalette { activeAppearance.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
            ZStack(alignment: .topLeading) {
                palette.canvas

                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                    RoundedRectangle(cornerRadius: RhymeAITokens.Radius.xs, style: .continuous)
                        .fill(palette.surface)
                        .frame(height: 18)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(palette.primaryInk)
                                .frame(width: 28, height: 3)
                                .padding(.leading, RhymeAITokens.Spacing.xxs)
                        }

                    Capsule()
                        .fill(palette.secondaryInk)
                        .frame(width: 38, height: 3)

                    Capsule()
                        .fill(palette.action)
                        .frame(width: 24, height: 7)
                }
                .padding(RhymeAITokens.Spacing.xs)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .clipShape(RoundedRectangle(cornerRadius: RhymeAITokens.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RhymeAITokens.Radius.sm, style: .continuous)
                    .strokeBorder(selected ? palette.outlineStrong : palette.outline, lineWidth: selected ? 2 : 1)
            }

            Text(style.displayName)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? activePalette.primaryInk : activePalette.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.displayName) preview")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

#Preview {
    AppearanceSettingsSection()
        .padding()
        .environment(\.appAppearanceStyle, .paper)
        .environment(\.appAppearanceBinding, .constant(.paper))
}
