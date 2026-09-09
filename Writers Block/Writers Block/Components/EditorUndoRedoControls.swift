import SwiftUI

struct EditorUndoRedoControls: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let canUndo: Bool
    let canRedo: Bool
    let floating: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
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
                .font(.body.weight(.semibold))
                .foregroundStyle(appearance.palette.primaryInk.opacity(isEnabled ? 1 : 0.35))
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                .background(
                    floating ? appearance.palette.surface : Color.clear,
                    in: Circle()
                )
                .overlay(
                    Circle().stroke(
                        floating ? appearance.palette.outlineStrong : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.rhymePress)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
