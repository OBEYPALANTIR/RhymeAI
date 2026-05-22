import SwiftUI

struct ExportSheet: View {
    var onPick: (ExportFormat) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pick a format. Save anywhere — Drive, Files, local — via the system picker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ForEach(ExportFormat.allCases) { format in
                    Button {
                        onPick(format)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: format.iconSystemName)
                                .foregroundStyle(.indigo)
                                .frame(width: 36, height: 36)
                                .liquidGlassSurface(cornerRadius: 8, tint: .indigo.opacity(0.14), fallbackOpacity: 0.08)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.label)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(format.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .liquidGlassSurface(cornerRadius: 12, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(20)
            .liquidGlassGroup(spacing: 16)
            .background(Color(UIColor.systemBackground))
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
