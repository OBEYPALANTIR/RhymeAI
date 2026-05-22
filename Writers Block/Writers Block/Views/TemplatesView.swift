import SwiftUI

struct TemplatesView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RhymeAITokens.Spacing.sm) {
                    ForEach(SongTemplate.builtIn) { template in
                        Button {
                            viewModel.applyTemplate(template)
                            dismiss()
                        } label: {
                            HStack(spacing: RhymeAITokens.Spacing.lg) {
                                Image(systemName: template.icon)
                                    .font(.title2)
                                    .foregroundStyle(.indigo)
                                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .indigo.opacity(0.16), fallbackOpacity: 0.10)

                                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                                    Text(template.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(template.theme)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                            .padding(RhymeAITokens.Spacing.lg)
                            .frame(minHeight: RhymeAITokens.Touch.minimum)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .indigo.opacity(0.08), interactive: true)
                        }
                        .buttonStyle(.rhymePress)
                    }
                }
                .frame(maxWidth: RhymeAITokens.Layout.assistantReadableWidth)
                .frame(maxWidth: .infinity)
                .padding(RhymeAITokens.Spacing.md)
                .liquidGlassGroup(spacing: RhymeAITokens.Spacing.sm)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("Choose a Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    TemplatesView()
        .environmentObject(EditorViewModel())
}
