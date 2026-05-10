import SwiftUI

struct RewriteChipBar: View {
    var onAction: (RewriteAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.indigo)
                .font(.caption.weight(.semibold))
            Text("Rewrite:")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(RewriteAction.allCases) { action in
                Button {
                    onAction(action)
                } label: {
                    Text(action.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.indigo.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(.indigo.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassSurface(cornerRadius: 20, interactive: true, fallbackOpacity: 0.85)
    }
}
