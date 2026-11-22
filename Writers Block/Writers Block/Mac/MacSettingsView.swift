#if os(macOS)
import SwiftUI

/// The Settings window: the iOS sections in Mac tabs. Everything applies as it
/// changes, as Mac preferences do: API keys save through the iOS Save path
/// when their field is committed, when the tab changes and when the window
/// closes, so a typed key is never dropped. A key that fails to save is shown
/// on every tab, and after the window closes in an alert.
extension SettingsView {
    var macBody: some View {
        TabView(selection: $macSettingsTab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                MacSettingsPage(error: saveError) {
                    AppearanceSettingsSection()
                    MenuBarCaptureSetting()
                }
            }
            Tab("AI & Models", systemImage: "sparkles", value: "ai") {
                MacSettingsPage(error: saveError) {
                    providerSection
                    providerSpecificSection
                    modelSection
                }
                .onDisappear(perform: saveKeysIfChanged)
            }
            Tab("Backup", systemImage: "externaldrive", value: "backup") {
                MacSettingsPage(error: saveError) { SettingsCloudBackupSection() }
            }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: "editor") {
                MacSettingsPage(error: saveError) { SettingsEditorSection(activeHelp: $activeHelp) }
            }
        }
        .onAppear(perform: loadSettingsState)
        .onDisappear(perform: saveKeysOnClose)
        .sheet(item: $activeHelp) { help in
            FeatureHelpSheet(help: help)
                .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
        }
    }

    /// The window is closing, so its error line can no longer be seen: a key
    /// that did not save is reported in an alert that can reopen Settings.
    private func saveKeysOnClose() {
        guard hasUnsavedKeys, !saveAll() else { return }
        let message = saveError ?? "Couldn't save the API key in the Keychain. Try again after unlocking the device."
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "API Key Not Saved"
            alert.informativeText = message
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                macSettingsTab = "ai"
                openSettingsWindow()
            }
        }
    }
}

/// One Settings tab: the sections on the canvas, scrolling when taller than
/// the window, under the API key save error when there is one.
private struct MacSettingsPage<Content: View>: View {
    @Environment(\.appAppearanceStyle) private var appearance
    let error: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settingsSaveError")
                }
                content
            }
            .padding(RhymeAITokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(appearance.palette.primaryInk)
        .background(appearance.palette.canvas)
    }
}
#endif
