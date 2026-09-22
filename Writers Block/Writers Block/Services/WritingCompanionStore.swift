import Foundation

struct KeptLyric: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var text: String
    var createdAt = Date()
}

struct DraftVersion: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var lyrics: String
    var theme: String
    var createdAt = Date()
}

struct WritingPosition: Codable, Equatable {
    var location = 0
    var length = 0
    var scrollY: Double = 0

    func clamped(to text: String) -> WritingPosition {
        let start = min(max(location, 0), text.utf16.count)
        return WritingPosition(location: start, length: min(max(length, 0), text.utf16.count - start), scrollY: scrollY.isFinite ? max(0, scrollY) : 0)
    }
}

struct WritingCompanion: Codable, Equatable {
    var alternates: [KeptLyric] = []
    var versions: [DraftVersion] = []
    var position = WritingPosition()

    mutating func keep(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !alternates.contains(where: { $0.text == trimmed }) else { return }
        alternates.insert(KeptLyric(text: trimmed), at: 0)
        alternates = Array(alternates.prefix(50))
    }

    mutating func checkpoint(title: String, lyrics: String, theme: String, now: Date = Date(), force: Bool = false) {
        guard [title, lyrics, theme].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        if let existing = versions.firstIndex(where: { $0.title == title && $0.lyrics == lyrics && $0.theme == theme }) {
            if force && existing > 0 {
                var version = versions.remove(at: existing)
                version.createdAt = now
                versions.insert(version, at: 0)
            }
            return
        }
        guard force || versions.first.map({ now.timeIntervalSince($0.createdAt) >= 300 }) ?? true else { return }
        versions.insert(DraftVersion(title: title, lyrics: lyrics, theme: theme, createdAt: now), at: 0)
        versions = Array(versions.prefix(20))
    }

    static func lyricPreview(_ lyrics: String) -> String? {
        lyrics.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && SectionMap.headerTitle($0) == nil }
    }
}

@MainActor
final class WritingCompanionStore {
    private let directory: URL?
    private var cache: [String: WritingCompanion] = [:]

    init(directory: URL? = nil, inMemory: Bool = false) {
        self.directory = inMemory ? nil : directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("WritingCompanions", isDirectory: true)
    }

    private func fileURL(_ id: String) -> URL? {
        let safeID = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return directory?.appendingPathComponent(safeID).appendingPathExtension("json")
    }

    func read(_ id: String) throws -> WritingCompanion {
        if let existing = cache[id] { return existing }
        guard let url = fileURL(id), FileManager.default.fileExists(atPath: url.path) else { return WritingCompanion() }
        let value = try JSONDecoder().decode(WritingCompanion.self, from: Data(contentsOf: url))
        cache[id] = value
        return value
    }

    func write(_ value: WritingCompanion, for id: String) throws {
        if let directory, let url = fileURL(id) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        cache[id] = value
    }

    func remove(_ id: String) throws {
        if let url = fileURL(id), FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        cache.removeValue(forKey: id)
    }
}
