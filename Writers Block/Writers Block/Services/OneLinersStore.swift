import Foundation
import SwiftData

/// A save that failed after its take was adopted. `takeNowAt` is where the take
/// really is now (back in pending, or still in place when the move back failed),
/// so a retry adopts it from there.
struct OneLinerSaveFailure: Error {
    let underlying: Error
    let takeNowAt: URL?
}

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
    /// Tests swap these to make a save or a file move fail.
    var saveContext: (ModelContext) throws -> Void = { try $0.save() }
    var moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    /// Called after a line goes to Trash, so its expiry gets scheduled.
    var onTrashed: () -> Void = {}

    /// Beside the voice-memos root, outside any song's folder.
    nonisolated static var defaultAudioRoot: URL {
        RecordingFiles.memosRoot().deletingLastPathComponent().appendingPathComponent("one-liners", isDirectory: true)
    }

    static let pendingFolderName = "pending"
    static let deletingFolderName = "deleting"
    /// A take older than this in `pendingRoot` was left by an app that closed mid-capture.
    static let abandonedTakeAge: TimeInterval = 24 * 60 * 60
    /// A set-aside file no row names is removed once it is this old.
    static let orphanAudioAge: TimeInterval = 7 * 24 * 60 * 60

    var pendingRoot: URL {
        audioRoot.appendingPathComponent(Self.pendingFolderName, isDirectory: true)
    }

    /// Audio set aside by a delete until the row's removal is saved.
    var deletingRoot: URL {
        audioRoot.appendingPathComponent(Self.deletingFolderName, isDirectory: true)
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
    /// first; if the save fails it is moved back and the failure says where the take
    /// is, so the caller still holds it.
    @discardableResult
    func add(text: String, take: URL? = nil, audioDuration: Double = 0, now: Date = Date()) throws -> OneLiner {
        var fileName: String?
        if let take {
            let name = take.lastPathComponent
            let destination = audioURL(fileName: name)
            try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
            // A retry after a failed move back finds the take already in place.
            if take.standardizedFileURL != destination.standardizedFileURL {
                try moveItem(take, destination)
            }
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
            guard let take, let fileName else { throw error }
            let adopted = audioURL(fileName: fileName)
            guard take.standardizedFileURL != adopted.standardizedFileURL else {
                throw OneLinerSaveFailure(underlying: error, takeNowAt: adopted)
            }
            let takeNowAt: URL
            do {
                try moveItem(adopted, take)
                takeNowAt = take
            } catch {
                takeNowAt = adopted  // still in place; a retry adopts it from here
            }
            throw OneLinerSaveFailure(underlying: error, takeNowAt: takeNowAt)
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
        onTrashed()
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

    /// The audio is set aside first (unless another row still uses it), the row is
    /// removed, and only once that is saved does the set-aside file go. A failed save
    /// puts the file back beside the row it still belongs to.
    func permanentlyDelete(_ trashed: TrashedOneLiner) throws {
        var staged: (original: URL, aside: URL)?
        if let fileName = trashed.audioFileName, try !isAudioReferenced(fileName, besides: trashed) {
            let original = audioURL(fileName: fileName)
            if FileManager.default.fileExists(atPath: original.path) {
                let aside = deletingRoot.appendingPathComponent(fileName, isDirectory: false)
                try FileManager.default.createDirectory(at: deletingRoot, withIntermediateDirectories: true)
                try removeIfPresent(aside)
                try moveItem(original, aside)
                staged = (original, aside)
            }
        }
        context.delete(trashed)
        do {
            try save()
        } catch {
            if let staged { try? moveItem(staged.aside, staged.original) }
            throw error
        }
        // A leftover here is removed by the next reconcile.
        if let staged { try? FileManager.default.removeItem(at: staged.aside) }
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

    /// Run at launch. Never deletes from the main folder: a take no row names may
    /// belong to a line iCloud has not delivered yet, so only delete forever and the
    /// Trash purge remove takes. A set-aside file a row still names (a delete that
    /// stopped before its save) goes back; other set-aside files go after a week, and
    /// pending takes an app left behind after a day.
    func reconcileAudioFiles(now: Date = Date()) throws {
        let lines = try context.fetch(FetchDescriptor<OneLiner>())
        let trashed = try context.fetch(FetchDescriptor<TrashedOneLiner>())
        let referenced = Set(lines.compactMap(\.audioFileName) + trashed.compactMap(\.audioFileName))
        for file in Self.files(in: deletingRoot) {
            let home = audioURL(fileName: file.lastPathComponent)
            if referenced.contains(file.lastPathComponent) {
                if !FileManager.default.fileExists(atPath: home.path) { try? moveItem(file, home) }
            } else {
                Self.remove(file, ifOlderThan: Self.orphanAudioAge, now: now)
            }
        }
        for take in Self.files(in: pendingRoot) {
            Self.remove(take, ifOlderThan: Self.abandonedTakeAge, now: now)
        }
    }

    private static func files(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
    }

    private static func remove(_ file: URL, ifOlderThan age: TimeInterval, now: Date) {
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(modified) > age else { return }
        try? FileManager.default.removeItem(at: file)
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
        let previous = (project.lyrics, project.updatedAt, project.precedenceRepaired)
        if let editor, editor.currentProjectId == project.id {
            // The marker is saved first: if that fails, nothing went into the song.
            try markUsed(line, projectId: project.id)
            editor.insertSuggestion(text)
            guard editor.flushCurrentDraft() else {
                // The failed draft save already wrote the song's loaded values, so the
                // song and the marker are put back explicitly before saving again.
                editor.undoLyrics()
                (project.lyrics, project.updatedAt, project.precedenceRepaired) = previous
                line.usedInProjectId = previousMarker
                try save()
                throw OneLinersStoreError.songNotSaved
            }
        } else {
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
