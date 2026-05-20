import SwiftUI

struct RewriteChipBar: View {
    var onAction: (RewriteAction) -> Void

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            ForEach(RewriteAction.allCases) { action in
                Button {
                    onAction(action)
                } label: {
                    Text(action.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
                        .liquidGlassSurface(
                            cornerRadius: RhymeAITokens.Radius.pill,
                            tint: .indigo.opacity(0.12),
                            interactive: true,
                            fallbackOpacity: 0.08
                        )
                }
                .buttonStyle(.rhymePress)
                .accessibilityIdentifier("rewriteAction_\(action.rawValue)")
            }
        }
        .padding(RhymeAITokens.Spacing.xs)
        .frame(maxWidth: RhymeAITokens.Layout.drawerMaxWidth)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill, tint: .indigo.opacity(0.08), fallbackOpacity: 0.85)
        .liquidGlassGroup(spacing: RhymeAITokens.Spacing.sm)
    }
}
