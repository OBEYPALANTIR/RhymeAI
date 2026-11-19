#if os(macOS)
import SwiftUI

/// The Settings window: the iOS sections in Mac tabs. Settings apply as they
/// change, as on iOS; API keys wait for Save. There is no Done: the window
/// closes like any Mac settings window, and an unsaved typed key is dropped.
extension SettingsView {
    var macBody: some View {
        TabView(selection: $macSettingsTab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                MacSettingsPage { AppearanceSettingsSection() }
            }
            Tab("AI & Models", systemImage: "sparkles", value: "ai") {
                MacSettingsPage {
                    providerSection
                    providerSpecificSection
                    modelSection
                } footer: {
                    keySaveFooter
                }
            }
            Tab("Backup", systemImage: "externaldrive", value: "backup") {
                MacSettingsPage { SettingsCloudBackupSection() }
            }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: "editor") {
                MacSettingsPage { SettingsEditorSection(activeHelp: $activeHelp) }
            }
        }
        .onAppear(perform: loadSettingsState)
        .sheet(item: $activeHelp) { help in
            FeatureHelpSheet(help: help)
                .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
        }
    }

    @ViewBuilder
    private var keySaveFooter: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settingsSaveError")
            }
            if hasUnsavedKeys {
                Text("Your API key is not saved yet. Other settings apply as you change them.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settingsUnsavedKeyNote")
            }
            SettingsSaveBar(saved: savedConfirmation, hasChanges: hasUnsavedKeys, action: { saveAll() })
        }
    }
}

/// One Settings tab: the sections on the canvas, scrolling, with an optional
/// bar pinned below.
private struct MacSettingsPage<Content: View, Footer: View>: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.lg) {
                    content
                }
                .padding(RhymeAITokens.Spacing.lg)
            }
            if Footer.self != EmptyView.self {
                Divider()
                footer
                    .padding(.horizontal, RhymeAITokens.Spacing.lg)
                    .padding(.vertical, RhymeAITokens.Spacing.sm)
                    .background(appearance.palette.surface)
            }
        }
        .foregroundStyle(appearance.palette.primaryInk)
        .background(appearance.palette.canvas)
    }
}

extension MacSettingsPage where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.footer = EmptyView()
    }
}
#endif
