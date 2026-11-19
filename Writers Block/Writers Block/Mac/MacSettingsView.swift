#if os(macOS)
import SwiftUI

/// The Settings window: the iOS sections in Mac tabs. Everything applies as it
/// changes, as Mac preferences do: API keys save through the iOS Save path
/// when their field is committed, when the tab changes and when the window
/// closes, so a typed key is never dropped.
extension SettingsView {
    var macBody: some View {
        TabView(selection: $macSettingsTab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                MacSettingsPage {
                    AppearanceSettingsSection()
                    MenuBarCaptureSetting()
                }
            }
            Tab("AI & Models", systemImage: "sparkles", value: "ai") {
                MacSettingsPage {
                    keySaveError
                    providerSection
                    providerSpecificSection
                    modelSection
                }
                .onDisappear(perform: saveKeysIfChanged)
            }
            Tab("Backup", systemImage: "externaldrive", value: "backup") {
                MacSettingsPage { SettingsCloudBackupSection() }
            }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: "editor") {
                MacSettingsPage { SettingsEditorSection(activeHelp: $activeHelp) }
            }
        }
        .onAppear(perform: loadSettingsState)
        .onDisappear(perform: saveKeysIfChanged)
        .sheet(item: $activeHelp) { help in
            FeatureHelpSheet(help: help)
                .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
        }
    }

    @ViewBuilder
    private var keySaveError: some View {
        if let saveError {
            Label(saveError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(appearance.palette.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settingsSaveError")
        }
    }
}

/// One Settings tab: the sections on the canvas, scrolling when taller than
/// the window.
private struct MacSettingsPage<Content: View>: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
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
