import SwiftUI

struct RewriteChipBar: View {
    var onAction: (RewriteAction) -> Void
    /// When non-nil (single-word selection), the bar shows a leading look-up
    /// button into the Word Inspector. Multi-word selections leave it nil and
    /// the rewrite actions fill the bar.
    var onInspect: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            if let onInspect {
                Button {
                    onInspect()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                        .liquidGlassSurface(
                            cornerRadius: RhymeAITokens.Radius.pill,
                            tint: .indigo.opacity(0.12),
                            interactive: true,
                            fallbackOpacity: 0.08
                        )
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Look up word")
                .accessibilityIdentifier("inspectAction")
            }
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
        .accessibilityIdentifier("rewriteChipBar")
    }
}
