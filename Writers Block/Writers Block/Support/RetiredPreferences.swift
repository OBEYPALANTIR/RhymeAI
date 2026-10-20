import Foundation

/// Settings the app no longer has. Their stored values are deleted at launch
/// so a later feature cannot pick up a stale choice under the same key.
nonisolated enum RetiredPreferences {
    /// The Analysis Style selector ("color" or "inkMarks"). Rhyme and syllable
    /// analysis is always shown in colour now.
    static let keys = ["analysisPresentationStyle"]

    static func remove(from defaults: UserDefaults = .standard) {
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
}
