#if os(macOS)
import SwiftUI
import SwiftData

/// The menu bar's "Catch a One Liner": type a line and press Return to save it
/// to One Liners, or hand off to the window's record and open flows.
struct MacQuickCaptureView: View {
    /// `UserDefaults` key for the Settings › General toggle that shows this.
    static let shownKey = "showsMenuBarQuickCapture"

    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.openWindow) private var openWindow
    let container: ModelContainer?
    @State private var text = ""
    @State private var status: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let palette = appearance.palette
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Text("Catch a One Liner")
                .font(.headline)
                .foregroundStyle(palette.primaryInk)
            TextField("Type a line, then press Return", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(save)
                .disabled(container == nil)
                .accessibilityIdentifier("quickCaptureField")
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryInk)
            }
            HStack {
                Button {
                    MacEditorWindow.bringForward(openWindow: openWindow)
                    OneLinerRouter.shared.request(.record)
                } label: {
                    Label("Record", systemImage: "mic")
                }
                .disabled(container == nil)
                Spacer()
                Button("Open One Liners") {
                    MacEditorWindow.bringForward(openWindow: openWindow)
                    OneLinerRouter.shared.request(.open)
                }
            }
        }
        .padding(RhymeAITokens.Spacing.sm)
        .frame(width: 300)
        .background(palette.canvas)
        .onAppear { fieldFocused = true }
    }

    private func save() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let container else { return }
        do {
            try OneLinersStore(context: container.mainContext).add(text: line)
            text = ""
            status = "Saved to One Liners"
        } catch {
            status = "Couldn't save the line. Try again."
        }
    }
}

/// Settings › General: whether the menu bar shows Catch a One Liner.
struct MenuBarCaptureSetting: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @AppStorage(MacQuickCaptureView.shownKey) private var shown = true

    var body: some View {
        // A card like Appearance above it.
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Label("Menu Bar", systemImage: "menubar.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.palette.secondaryInk)
                .textCase(.uppercase)
            Toggle("Show quick capture in the menu bar", isOn: $shown)
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(appearance.palette.primaryInk)
                .accessibilityIdentifier("menuBarQuickCaptureToggle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: SettingsMetrics.groupRadius)
    }
}

/// The editor is one window on the shared view model: bring it back if it
/// is open or minimized, and open it again only after it was closed.
enum MacEditorWindow {
    static func bringForward(openWindow: OpenWindowAction) {
        NSApp.activate()
        let editor = NSApp.windows.first { window in
            window.identifier?.rawValue.hasPrefix(Writers_BlockApp.editorWindowID) == true
                && (window.isVisible || window.isMiniaturized)
        }
        if let editor {
            if editor.isMiniaturized { editor.deminiaturize(nil) }
            editor.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: Writers_BlockApp.editorWindowID)
        }
    }
}
#endif
