import Foundation
import SwiftData

/// Reads and writes the One Liners pool. The views keep their own `@Query`
/// lists; this owns every change so trash, restore and send behave the same
/// from any screen.
// TODO: back up one liners (and their audio) with GoogleDriveBackupService once manifest v4 carries them.
struct OneLinersStore {
    let context: ModelContext
    var audioRoot: URL = OneLinersStore.defaultAudioRoot

    /// Beside the voice-memos root, outside any song's folder.
    nonisolated static var defaultAudioRoot: URL {
        RecordingFiles.memosRoot().deletingLastPathComponent().appendingPathComponent("one-liners", isDirectory: true)
    }

    func audioURL(fileName: String) -> URL {
        audioRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Newest first.
    func all() throws -> [OneLiner] {
        try context.fetch(FetchDescriptor<OneLiner>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    func search(_ query: String) throws -> [OneLiner] {
        Self.filter(try all(), query: query)
    }

    /// Case-insensitive substring match; a blank query keeps everything.
    static func filter(_ lines: [OneLiner], query: String) -> [OneLiner] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    @discardableResult
    func add(text: String, audioFileName: String? = nil, audioDuration: Double = 0, now: Date = Date()) throws -> OneLiner {
        let line = OneLiner(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            audioFileName: audioFileName,
            audioDuration: audioDuration
        )
        context.insert(line)
        try save()
        return line
    }

    @discardableResult
    func trash(_ line: OneLiner, now: Date = Date()) throws -> TrashedOneLiner {
        let trashed = TrashedOneLiner(oneLiner: line, deletedAt: now)
        let id = line.id
        // Ids are unique by this code, not the schema (CloudKit): one Trash copy per line.
        try context.fetch(FetchDescriptor<TrashedOneLiner>(predicate: #Predicate { $0.id == id })).forEach(context.delete)
        context.insert(trashed)
        context.delete(line)
        try save()
        return trashed
    }

    @discardableResult
    func restore(_ trashed: TrashedOneLiner) throws -> OneLiner {
        let line = trashed.restoredOneLiner()
        let id = line.id
        try context.fetch(FetchDescriptor<OneLiner>(predicate: #Predicate { $0.id == id })).forEach(context.delete)
        context.insert(line)
        context.delete(trashed)
        try save()
        return line
    }

    func permanentlyDelete(_ trashed: TrashedOneLiner) throws {
        let fileName = trashed.audioFileName
        context.delete(trashed)
        try save()
        if let fileName { try? FileManager.default.removeItem(at: audioURL(fileName: fileName)) }
    }

    func purgeExpired(now: Date = Date()) throws {
        let expired = try context.fetch(FetchDescriptor<TrashedOneLiner>(predicate: #Predicate { $0.deleteAfter <= now }))
        for trashed in expired { try permanentlyDelete(trashed) }
    }

    func markUsed(_ line: OneLiner, projectId: String) throws {
        line.usedInProjectId = projectId
        try save()
    }

    /// Puts the line into the song: at the editor's cursor when that song is the
    /// open one (one undoable edit the editor saves), otherwise as a new last line.
    func sendToSong(_ line: OneLiner, project: SongProject, editor: EditorViewModel?) throws {
        if let editor, editor.currentProjectId == project.id {
            editor.insertSuggestion(line.text)
        } else {
            project.lyrics = Self.appendingLine(line.text, to: project.lyrics)
            project.updatedAt = Date()
            project.precedenceRepaired = false  // an edit beats a repair (A37)
        }
        try markUsed(line, projectId: project.id)
    }

    static func appendingLine(_ line: String, to lyrics: String) -> String {
        if lyrics.isEmpty { return line }
        return lyrics.hasSuffix("\n") ? lyrics + line : lyrics + "\n" + line
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
