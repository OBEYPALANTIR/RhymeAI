import SwiftUI

struct RewriteSheet: View {
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
                VStack(alignment: .leading, spacing: 16) {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(original)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.primary.opacity(0.8))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Rewrite")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)

                    Group {
                        if loading {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Thinking...").foregroundStyle(.secondary)
                            }
                        } else if let error {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
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
                    .padding(12)
                    .background(Color.indigo.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.indigo.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(20)
            }
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
        .preferredColorScheme(.dark)
    }
}
