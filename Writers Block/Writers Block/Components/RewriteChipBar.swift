import SwiftUI

struct RewriteChipBar: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var onAction: (RewriteAction) -> Void
    /// When non-nil (single-word selection), the bar shows a leading look-up
    /// button into the Word Inspector. Multi-word selections leave it nil and
    /// the rewrite actions fill the bar.
    var onInspect: (() -> Void)? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Equal-width chips would cut the labels down to "Rephra…";
                // full-width labels in a scrolling row keep the bar one line
                // tall so it does not cover the lyrics above the keyboard.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RhymeAITokens.Spacing.xs) { chips(naturalWidth: true) }
                }
            } else {
                HStack(spacing: RhymeAITokens.Spacing.xs) { chips(naturalWidth: false) }
            }
        }
        .padding(RhymeAITokens.Spacing.xs)
        .frame(maxWidth: RhymeAITokens.Layout.drawerMaxWidth)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill)
        .liquidGlassGroup(spacing: RhymeAITokens.Spacing.sm)
        .accessibilityIdentifier("rewriteChipBar")
    }

    @ViewBuilder
    private func chips(naturalWidth: Bool) -> some View {
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
                    .minimumScaleFactor(naturalWidth ? 1 : 0.86)
                    .padding(.horizontal, naturalWidth ? RhymeAITokens.Spacing.sm : 0)
                    .fixedSize(horizontal: naturalWidth, vertical: false)
                    .frame(maxWidth: naturalWidth ? nil : .infinity, minHeight: RhymeAITokens.Touch.minimum)
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
}
