import SwiftUI

struct EditorUndoRedoControls: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        // Same gap as the rest of the top bar, so the leading group reads as
        // one evenly spaced run.
        HStack(spacing: RhymeAITokens.Spacing.xxs) {
            historyButton(
                systemImage: "arrow.uturn.backward",
                accessibilityLabel: "Undo last edit",
                accessibilityIdentifier: "undoLyricsButton",
                isEnabled: canUndo,
                action: onUndo
            )
            historyButton(
                systemImage: "arrow.uturn.forward",
                accessibilityLabel: "Redo last edit",
                accessibilityIdentifier: "redoLyricsButton",
                isEnabled: canRedo,
                action: onRedo
            )
        }
    }

    private func historyButton(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(appearance.palette.secondaryInk.opacity(isEnabled ? 1 : 0.35))
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
        }
        .buttonStyle(.rhymePress)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
