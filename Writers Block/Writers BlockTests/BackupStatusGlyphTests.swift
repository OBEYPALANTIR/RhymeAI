import Foundation
import SwiftUI
import Testing
@testable import Writers_Block

/// The Backup status glyph wears the success colour at the save indicator's
/// 80% exactly while the row reads "Last backed up just now" (under 60s),
/// the error colour while failed, and secondary ink otherwise.
struct BackupStatusGlyphTests {
    private let now = Date(timeIntervalSince1970: 1_780_374_654)

    private func color(_ status: BackupStatus, _ style: AppAppearanceStyle = .ink) -> Color {
        SettingsCloudBackupSection.providerStatusIconColor(status, now: now, palette: style.palette)
    }

    @Test func justNowWearsSuccessAtEightyPercentOnEveryAppearance() {
        for style in [AppAppearanceStyle.ink, .paper, .graphite] {
            let expected = style.palette.success.opacity(EditorViewConstants.TopBar.savedStatusOpacity)
            #expect(color(.connected(lastBackupAt: now), style) == expected)
            #expect(color(.connected(lastBackupAt: now.addingTimeInterval(-59.9)), style) == expected)
            #expect(expected != style.palette.success, "80%, not full opacity")
        }
        #expect(EditorViewConstants.TopBar.savedStatusOpacity == 0.8)
    }

    @Test(arguments: [AppAppearanceStyle.ink, .paper, .graphite])
    func theSuccessColourLeavesAtTheMinute(_ style: AppAppearanceStyle) {
        let ink = style.palette.secondaryInk
        #expect(color(.connected(lastBackupAt: now.addingTimeInterval(-60)), style) == ink)
        #expect(color(.connected(lastBackupAt: now.addingTimeInterval(-3_600)), style) == ink)
        #expect(color(.connected(lastBackupAt: nil), style) == ink, "Not backed up yet")
    }

    @Test(arguments: [AppAppearanceStyle.ink, .paper, .graphite])
    func theOtherStatesStayInSecondaryInkAndAFailureIsTheErrorColour(_ style: AppAppearanceStyle) {
        let palette = style.palette
        #expect(color(.notConnected, style) == palette.secondaryInk)
        #expect(color(.pending, style) == palette.secondaryInk)
        #expect(color(.backingUp, style) == palette.secondaryInk)
        #expect(color(.failed(reason: "Backup failed.", lastBackupAt: now), style) == palette.error, "a failure is never green, even seconds after a backup")
    }

    @Test func justNowIsTheFirstMinute() {
        #expect(SettingsCloudBackupSection.isJustBackedUp(now, now: now))
        #expect(!SettingsCloudBackupSection.isJustBackedUp(now.addingTimeInterval(-60), now: now))
        #expect(!SettingsCloudBackupSection.isJustBackedUp(nil, now: now))
    }
}
