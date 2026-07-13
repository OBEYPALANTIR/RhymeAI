import SwiftUI

struct RewriteSheet: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let action: RewriteAction
    let original: String
    let preview: String?
    let loading: Bool
    let error: String?
    var onApply: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(original)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.primary.opacity(0.8))
                        .padding(RhymeAITokens.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.sm)

                    Text("Rewrite")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.palette.action)

                    Group {
                        if loading {
                            HStack(spacing: RhymeAITokens.Spacing.xs) {
                                ProgressView().scaleEffect(0.8)
                                Text("Thinking...").foregroundStyle(.secondary)
                            }
                        } else if let error {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(appearance.palette.error)
                        } else if let preview {
                            Text(preview)
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(.primary)
                        } else {
                            Text("No rewrite returned.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(RhymeAITokens.Spacing.sm)
                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.sm)
                }
                .padding(RhymeAITokens.Spacing.md)
                .liquidGlassGroup(spacing: RhymeAITokens.Spacing.sm)
            }
            .background(AppWritingBackground())
            .navigationTitle(action.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: onApply)
                        .disabled(preview == nil || loading)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
