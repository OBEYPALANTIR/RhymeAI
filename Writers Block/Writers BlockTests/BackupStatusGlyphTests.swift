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

    @Test func theSuccessColourLeavesAtTheMinute() {
        let ink = AppAppearanceStyle.ink.palette.secondaryInk
        #expect(color(.connected(lastBackupAt: now.addingTimeInterval(-60))) == ink)
        #expect(color(.connected(lastBackupAt: now.addingTimeInterval(-3_600))) == ink)
        #expect(color(.connected(lastBackupAt: nil)) == ink, "Not backed up yet")
    }

    @Test func theOtherStatesStayInSecondaryInkAndAFailureIsTheErrorColour() {
        let palette = AppAppearanceStyle.ink.palette
        #expect(color(.notConnected) == palette.secondaryInk)
        #expect(color(.pending) == palette.secondaryInk)
        #expect(color(.backingUp) == palette.secondaryInk)
        #expect(color(.failed(reason: "Backup failed.", lastBackupAt: now)) == palette.error, "a failure is never green, even seconds after a backup")
    }

    @Test func justNowIsTheFirstMinute() {
        #expect(SettingsCloudBackupSection.isJustBackedUp(now, now: now))
        #expect(!SettingsCloudBackupSection.isJustBackedUp(now.addingTimeInterval(-60), now: now))
        #expect(!SettingsCloudBackupSection.isJustBackedUp(nil, now: now))
    }
}
