import Foundation
import WidgetKit

/// What the Home Screen widgets show, written by the app into the App Group
/// container. The widgets never open the SwiftData store; they read only this file.
struct OneLinersSnapshot: Codable, Equatable {
    struct Line: Codable, Equatable, Identifiable {
        let id: String
        let text: String
        let createdAt: Date
        let hasAudio: Bool
    }

    var count: Int
    /// Newest first, at most `lineLimit`.
    var lines: [Line]
    /// The app's `AppAppearanceStyle` raw value, so the widgets match it.
    var appearance: String

    static let appGroupIdentifier = "group.ShaydeTree.Writers-Block"
    static let widgetKind = "OneLinersWidget"
    static let lineLimit = 3
    static let empty = OneLinersSnapshot(count: 0, lines: [], appearance: AppAppearanceStyle.ink.rawValue)

    /// Nil when the App Group is not in this build's entitlements, and in hosted unit
    /// tests, which never write the simulator's real widget snapshot.
    static var defaultURL: URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("one-liners-snapshot.json", isDirectory: false)
    }

    static func read(from url: URL?) -> OneLinersSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OneLinersSnapshot.self, from: data)
    }

    /// Writes the file and reloads the widgets, only when the content changed.
    /// Returns whether it wrote.
    @discardableResult
    func publish(to url: URL) throws -> Bool {
        guard Self.read(from: url) != self else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        return true
    }
}
