import SwiftUI

struct RewriteChipBar: View {
    @Environment(\.appAppearanceStyle) private var appearance

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
                        .foregroundStyle(appearance.palette.action)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                        .liquidGlassSurface(
                            cornerRadius: RhymeAITokens.Radius.pill,
                            interactive: true,
                            fallbackOpacity: 0.08
                        )
                        // Make the whole 44pt frame tappable. The bare glyph is
                        // only ~12pt, so taps near its edges fell through to the
                        // text view behind the bar — the look-up appeared dead.
                        .contentShape(Rectangle())
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
                        .foregroundStyle(appearance.palette.action)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
                        .liquidGlassSurface(
                            cornerRadius: RhymeAITokens.Radius.pill,
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
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill)
        .liquidGlassGroup(spacing: RhymeAITokens.Spacing.sm)
        .accessibilityIdentifier("rewriteChipBar")
    }
}
