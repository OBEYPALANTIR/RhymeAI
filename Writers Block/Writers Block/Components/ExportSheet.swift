import SwiftUI

struct ExportSheet: View {
    @Environment(\.appAppearanceStyle) private var appearance

    var onPick: (ExportFormat) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            // Scrolls so larger text sizes wrap instead of truncating.
            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                    Text("Pick a format. Save anywhere — Drive, Files, local — via the system picker.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, RhymeAITokens.Spacing.xxs)

                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            onPick(format)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: format.iconSystemName)
                                    .foregroundStyle(appearance.palette.action)
                                    .frame(width: 36, height: 36)
                                    .liquidGlassSurface(cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.label)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(format.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, RhymeAITokens.Spacing.sm)
                            .padding(.vertical, RhymeAITokens.Spacing.sm)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, interactive: true)
                        }
                        .buttonStyle(.rhymePress)
                    }
                }
                .padding(RhymeAITokens.Spacing.md)
                .liquidGlassGroup(spacing: RhymeAITokens.Spacing.sm)
            }
            .background(AppWritingBackground())
            .navigationTitle("Export Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
            }
        }
    }
}
