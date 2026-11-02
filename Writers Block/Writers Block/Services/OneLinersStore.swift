import Foundation
import SwiftData

enum OneLinersStoreError: LocalizedError, Equatable {
    /// An audio-only line has no words to put into a song.
    case noWords
    /// The open song could not be saved with the line, so nothing changed.
    case songNotSaved

    var errorDescription: String? {
        switch self {
        case .noWords: "Transcribe or type the words first."
        case .songNotSaved: "Couldn't add the line to the open song. Try again in a moment."
        }
    }
}

/// Reads and writes the One Liners pool. The views keep their own `@Query`
/// lists; this owns every change so trash, restore and send behave the same
/// from any screen. Audio lives in `audioRoot` (one file per line, named in
/// the row); takes being recorded stay in `pendingRoot` until a save adopts them.
// TODO: back up one liners (and their audio) with GoogleDriveBackupService once manifest v4 carries them.
struct OneLinersStore {
    let context: ModelContext
    var audioRoot: URL = OneLinersStore.defaultAudioRoot
    /// Tests swap this to make a save fail.
    var saveContext: (ModelContext) throws -> Void = { try $0.save() }

    /// Beside the voice-memos root, outside any song's folder.
    nonisolated static var defaultAudioRoot: URL {
        RecordingFiles.memosRoot().deletingLastPathComponent().appendingPathComponent("one-liners", isDirectory: true)
    }

    static let pendingFolderName = "pending"
    /// A take older than this in `pendingRoot` was left by an app that closed mid-capture.
    static let abandonedTakeAge: TimeInterval = 24 * 60 * 60

    var pendingRoot: URL {
        audioRoot.appendingPathComponent(Self.pendingFolderName, isDirectory: true)
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

    /// Saves a new line. A take is moved from its pending place into `audioRoot`
    /// first; if the save fails it is moved back, so the caller still holds it.
    @discardableResult
    func add(text: String, take: URL? = nil, audioDuration: Double = 0, now: Date = Date()) throws -> OneLiner {
        let fileManager = FileManager.default
        var fileName: String?
        if let take {
            let name = take.lastPathComponent
            try fileManager.createDirectory(at: audioRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: take, to: audioURL(fileName: name))
            fileName = name
        }
        let line = OneLiner(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            audioFileName: fileName,
            audioDuration: audioDuration
        )
        context.insert(line)
        do {
            try save()
        } catch {
            if let take, let fileName { try? fileManager.moveItem(at: audioURL(fileName: fileName), to: take) }
            throw error
        }
        return line
    }

    /// New words for a line (typed after an audio-only capture, or a fix); the prosody follows.
    func updateText(_ line: OneLiner, to text: String) throws {
        let previous = line.text
        line.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        line.refreshProsody()
        do {
            try save()
        } catch {
            // A rollback does not put back values already set on a loaded model.
            line.text = previous
            line.refreshProsody()
            throw error
        }
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

    /// Restores the line and drops every Trash copy of it, including ones another
    /// device made, so no leftover copy can later expire the line's audio.
    @discardableResult
    func restore(_ trashed: TrashedOneLiner) throws -> OneLiner {
        let line = trashed.restoredOneLiner()
        let id = line.id
        try context.fetch(FetchDescriptor<OneLiner>(predicate: #Predicate { $0.id == id })).forEach(context.delete)
        try context.fetch(FetchDescriptor<TrashedOneLiner>(predicate: #Predicate { $0.id == id })).forEach(context.delete)
        context.insert(line)
        try save()
        return line
    }

    /// The audio goes first, unless another row still uses it; when the file cannot
    /// be removed the row stays, so the delete can be tried again.
    func permanentlyDelete(_ trashed: TrashedOneLiner) throws {
        if let fileName = trashed.audioFileName, try !isAudioReferenced(fileName, besides: trashed) {
            try removeIfPresent(audioURL(fileName: fileName))
        }
        context.delete(trashed)
        try save()
    }

    func purgeExpired(now: Date = Date()) throws {
        let expired = try context.fetch(FetchDescriptor<TrashedOneLiner>(predicate: #Predicate { $0.deleteAfter <= now }))
        for trashed in expired { try permanentlyDelete(trashed) }
    }

    /// The next time a Trash copy expires, for the editor's Trash scheduler.
    func nextExpiry(after now: Date = Date()) -> Date? {
        var descriptor = FetchDescriptor<TrashedOneLiner>(
            predicate: #Predicate { $0.deleteAfter > now },
            sortBy: [SortDescriptor(\.deleteAfter, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.deleteAfter
    }

    /// Removes audio no row names any more (a line deleted on another device, or a
    /// removal that failed), and takes an app left pending for over a day.
    func reconcileAudioFiles(now: Date = Date()) throws {
        let fileManager = FileManager.default
        let lines = try context.fetch(FetchDescriptor<OneLiner>())
        let trashed = try context.fetch(FetchDescriptor<TrashedOneLiner>())
        let referenced = Set(lines.compactMap(\.audioFileName) + trashed.compactMap(\.audioFileName))
        let files = (try? fileManager.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        // No rows at all beside files means the store was emptied (an iCloud account
        // change resets it before downloading again): keep everything.
        if !(lines.isEmpty && trashed.isEmpty) {
            for file in files where file.lastPathComponent != Self.pendingFolderName && !referenced.contains(file.lastPathComponent) {
                try? fileManager.removeItem(at: file)
            }
        }
        let pending = (try? fileManager.contentsOfDirectory(at: pendingRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for take in pending {
            let modified = try? take.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, now.timeIntervalSince(modified) > Self.abandonedTakeAge { try? fileManager.removeItem(at: take) }
        }
    }

    func markUsed(_ line: OneLiner, projectId: String) throws {
        let previous = line.usedInProjectId
        line.usedInProjectId = projectId
        do {
            try save()
        } catch {
            line.usedInProjectId = previous
            throw error
        }
    }

    /// Puts the line into the song: at the editor's cursor when that song is the
    /// open one (one undoable edit, saved right away), otherwise as a new last line.
    /// Either the song and the used marker are both saved, or neither changes.
    func sendToSong(_ line: OneLiner, project: SongProject, editor: EditorViewModel?) throws {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OneLinersStoreError.noWords }
        let previousMarker = line.usedInProjectId
        if let editor, editor.currentProjectId == project.id {
            // The marker is saved first: if that fails, nothing went into the song.
            try markUsed(line, projectId: project.id)
            editor.insertSuggestion(text)
            guard editor.flushCurrentDraft() else {
                editor.undoLyrics()
                line.usedInProjectId = previousMarker
                try? save()
                throw OneLinersStoreError.songNotSaved
            }
        } else {
            let previous = (project.lyrics, project.updatedAt, project.precedenceRepaired)
            line.usedInProjectId = project.id
            project.lyrics = Self.appendingLine(text, to: project.lyrics)
            project.updatedAt = Date()
            project.precedenceRepaired = false  // an edit beats a repair (A37)
            do {
                try save()  // one save for the song and the marker
            } catch {
                // A rollback does not put back values already set on a loaded model.
                (project.lyrics, project.updatedAt, project.precedenceRepaired) = previous
                line.usedInProjectId = previousMarker
                throw error
            }
        }
    }

    static func appendingLine(_ line: String, to lyrics: String) -> String {
        if lyrics.isEmpty { return line }
        return lyrics.hasSuffix("\n") ? lyrics + line : lyrics + "\n" + line
    }

    private func isAudioReferenced(_ fileName: String, besides trashed: TrashedOneLiner) throws -> Bool {
        let name: String? = fileName
        if try context.fetchCount(FetchDescriptor<OneLiner>(predicate: #Predicate { $0.audioFileName == name })) > 0 {
            return true
        }
        return try context.fetch(FetchDescriptor<TrashedOneLiner>(predicate: #Predicate { $0.audioFileName == name }))
            .contains { $0.persistentModelID != trashed.persistentModelID }
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private func save() throws {
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
    }
}
