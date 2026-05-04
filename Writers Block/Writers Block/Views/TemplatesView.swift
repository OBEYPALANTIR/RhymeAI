import SwiftUI

struct TemplatesView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(SongTemplate.builtIn) { template in
                        Button {
                            viewModel.applyTemplate(template)
                            dismiss()
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: template.icon)
                                    .font(.title2)
                                    .foregroundStyle(.indigo)
                                    .frame(width: 44, height: 44)
                                    .background(Color.indigo.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 4) {
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
                            .padding(16)
                            .liquidGlassSurface(cornerRadius: 16, tint: .indigo.opacity(0.08), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
                .padding(20)
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
        .preferredColorScheme(.dark)
    }
}

#Preview {
    TemplatesView()
        .environmentObject(EditorViewModel())
}
