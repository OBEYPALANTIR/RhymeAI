import Foundation
import Testing
@testable import Writers_Block

/// The Backup status glyph wears the success colour exactly while the row
/// reads "Last backed up just now" (under 60s), then returns to secondary ink.
struct BackupStatusGlyphTests {
    private let now = Date(timeIntervalSince1970: 1_780_374_654)

    @Test func justNowCoversTheFirstMinute() {
        #expect(SettingsCloudBackupSection.isJustBackedUp(now, now: now))
        #expect(SettingsCloudBackupSection.isJustBackedUp(now.addingTimeInterval(-59.9), now: now))
    }

    @Test func theSuccessColourLeavesAtTheMinute() {
        #expect(!SettingsCloudBackupSection.isJustBackedUp(now.addingTimeInterval(-60), now: now))
        #expect(!SettingsCloudBackupSection.isJustBackedUp(now.addingTimeInterval(-3_600), now: now))
    }

    @Test func noBackupYetIsNotJustNow() {
        #expect(!SettingsCloudBackupSection.isJustBackedUp(nil, now: now))
    }
}
