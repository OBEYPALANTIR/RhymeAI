import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct TrashLifecycleTests {

    @MainActor
    @Test func moveProjectToTrashClearsCurrentEditorAndCreatesTrashEntry() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let updatedAt = Date(timeIntervalSince1970: 1_780_374_654)
        let project = SongProject(
            id: "song-1",
            title: "Draft",
            lyrics: "yellow music",
            theme: "late-night resolve",
            updatedAt: updatedAt
        )
        context.insert(project)
        try context.save()

        viewModel.title = project.title
        viewModel.lyrics = project.lyrics
        viewModel.theme = project.theme
        viewModel.currentProjectId = project.id
        viewModel.suggestions = [SuggestedLine(text: "keep this clear", tier: 0)]

        viewModel.moveProjectToTrash(project)

        let activeProjects = try Self.fetchProjects(context)
        let trash = try Self.fetchTrash(context)
        let trashed = try #require(trash.first)

        #expect(activeProjects.isEmpty)
        #expect(trash.count == 1)
        #expect(trashed.id == "song-1")
        #expect(trashed.title == "Draft")
        #expect(trashed.lyrics == "yellow music")
        #expect(trashed.theme == "late-night resolve")
        #expect(trashed.updatedAt == updatedAt)
        #expect(trashed.deleteAfter.timeIntervalSince(trashed.deletedAt) == trashRetentionInterval)
        #expect(viewModel.currentProjectId == nil)
        #expect(viewModel.title.isEmpty)
        #expect(viewModel.lyrics.isEmpty)
        #expect(viewModel.theme.isEmpty)
        #expect(viewModel.suggestions.isEmpty)
    }

    @MainActor
    @Test func moveProjectToTrashReplacesDuplicateTrashEntries() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let updatedAt = Date(timeIntervalSince1970: 1_780_500_000)
        let project = SongProject(
            id: "song-1",
            title: "Current Draft",
            lyrics: "current lyrics",
            theme: "new direction",
            updatedAt: updatedAt
        )
        let staleTrash = TrashedSongProject(
            id: "song-1",
            title: "Stale Trash",
            lyrics: "old lyrics",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 100),
            deletedAt: Date(timeIntervalSince1970: 200)
        )
        let duplicateTrash = TrashedSongProject(
            id: "song-1",
            title: "Duplicate Trash",
            lyrics: "older lyrics",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 50),
            deletedAt: Date(timeIntervalSince1970: 150)
        )
        context.insert(project)
        context.insert(staleTrash)
        context.insert(duplicateTrash)
        try context.save()

        viewModel.moveProjectToTrash(project)

        let activeProjects = try Self.fetchProjects(context)
        let trash = try Self.fetchTrash(context)
        let trashed = try #require(trash.first)

        #expect(activeProjects.isEmpty)
        #expect(trash.count == 1)
        #expect(trashed.id == "song-1")
        #expect(trashed.title == "Current Draft")
        #expect(trashed.lyrics == "current lyrics")
        #expect(trashed.theme == "new direction")
        #expect(trashed.updatedAt == updatedAt)
    }

    @MainActor
    @Test func restoreTrashedProjectReplacesExistingActiveProject() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let staleActive = SongProject(
            id: "song-1",
            title: "Stale Active",
            lyrics: "old lyrics",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let trashed = TrashedSongProject(
            id: "song-1",
            title: "Restored Draft",
            lyrics: "new lyrics",
            theme: "clear signal",
            updatedAt: Date(timeIntervalSince1970: 200),
            deletedAt: Date(timeIntervalSince1970: 300)
        )
        context.insert(staleActive)
        context.insert(trashed)
        try context.save()

        viewModel.restoreTrashedProject(trashed)

        let activeProjects = try Self.fetchProjects(context)
        let restored = try #require(activeProjects.first)

        #expect(activeProjects.count == 1)
        #expect(restored.id == "song-1")
        #expect(restored.title == "Restored Draft")
        #expect(restored.lyrics == "new lyrics")
        #expect(restored.theme == "clear signal")
        #expect(restored.updatedAt > trashed.deletedAt)
        #expect(try Self.fetchTrash(context).isEmpty)
    }

    @MainActor
    @Test func restoreTrashedProjectCollapsesDuplicateActiveAndTrashRows() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let staleActive = SongProject(
            id: "song-1",
            title: "Stale Active",
            lyrics: "old lyrics",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let duplicateActive = SongProject(
            id: "song-1",
            title: "Duplicate Active",
            lyrics: "duplicate lyrics",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 90)
        )
        let trashed = TrashedSongProject(
            id: "song-1",
            title: "Restored Draft",
            lyrics: "new lyrics",
            theme: "clear signal",
            updatedAt: Date(timeIntervalSince1970: 200),
            deletedAt: Date(timeIntervalSince1970: 300)
        )
        let duplicateTrash = TrashedSongProject(
            id: "song-1",
            title: "Duplicate Trash",
            lyrics: "old deleted lyrics",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 80),
            deletedAt: Date(timeIntervalSince1970: 250)
        )
        context.insert(staleActive)
        context.insert(duplicateActive)
        context.insert(trashed)
        context.insert(duplicateTrash)
        try context.save()

        viewModel.restoreTrashedProject(trashed)

        let activeProjects = try Self.fetchProjects(context)
        let restored = try #require(activeProjects.first)

        #expect(activeProjects.count == 1)
        #expect(restored.id == "song-1")
        #expect(restored.title == "Restored Draft")
        #expect(restored.lyrics == "new lyrics")
        #expect(restored.theme == "clear signal")
        #expect(try Self.fetchTrash(context).isEmpty)
    }

    @MainActor
    @Test func purgeExpiredTrashedProjectsKeepsUnexpiredTrash() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let now = Date()
        let expired = TrashedSongProject(
            id: "expired",
            title: "Expired",
            lyrics: "",
            theme: "",
            updatedAt: now,
            deletedAt: now.addingTimeInterval(-trashRetentionInterval - 60),
            deleteAfter: now.addingTimeInterval(-60)
        )
        let retained = TrashedSongProject(
            id: "retained",
            title: "Retained",
            lyrics: "",
            theme: "",
            updatedAt: now,
            deletedAt: now,
            deleteAfter: now.addingTimeInterval(60)
        )
        context.insert(expired)
        context.insert(retained)
        try context.save()

        viewModel.purgeExpiredTrashedProjects()

        let trashIds = try Self.fetchTrash(context).map(\.id)

        #expect(trashIds == ["retained"])
        #expect(try Self.fetchDeletions(context).map(\.projectId) == ["expired"])
    }

    @MainActor
    @Test func permanentProjectDeletePersistsTombstoneBeforeRemovingTrash() async throws {
        let harness = try Self.makeHarness()
        let trashed = TrashedSongProject(
            id: "gone",
            title: "Gone",
            lyrics: "private draft",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 100),
            deletedAt: Date(timeIntervalSince1970: 200)
        )
        harness.context.insert(trashed)
        try harness.context.save()

        #expect(harness.viewModel.permanentlyDeleteTrashedProject(trashed))
        #expect(try Self.fetchTrash(harness.context).isEmpty)
        let tombstone = try #require(Self.fetchDeletions(harness.context).first)
        #expect(tombstone.projectId == "gone")
        #expect(tombstone.fileName == nil)
    }

    @MainActor
    @Test func persistedTombstoneSuppressesStaleProjectOnRelaunch() async throws {
        let harness = try Self.makeHarness()
        harness.context.insert(SongProject(id: "gone", title: "Stale", lyrics: "stale lyric", updatedAt: Date(timeIntervalSince1970: 100)))
        harness.context.insert(SyncDeletionRecord(projectId: "gone", deletedAt: 200_000))
        try harness.context.save()

        let relaunched = EditorViewModel()
        relaunched.modelContext = harness.context

        #expect(try Self.fetchProjects(harness.context).isEmpty)
        #expect(try Self.fetchDeletions(harness.context).map(\.projectId) == ["gone"])
    }

    @MainActor
    @Test func songEditedAfterItsTombstoneSurvivesRelaunch() async throws {
        let harness = try Self.makeHarness()
        harness.context.insert(SongProject(id: "back", title: "Edited later", lyrics: "kept", updatedAt: Date(timeIntervalSince1970: 300)))
        harness.context.insert(SyncDeletionRecord(projectId: "back", deletedAt: 200_000))
        try harness.context.save()

        let relaunched = EditorViewModel()
        relaunched.modelContext = harness.context

        #expect(try Self.fetchProjects(harness.context).map(\.id) == ["back"])
    }

    @MainActor
    @Test func permanentRecordingDeleteRejectsSymlinkedTrashParent() async throws {
        let fixture = try RecordingTrashFixture(symlinkedParent: true)
        defer { fixture.cleanUp() }
        let service = VoiceMemoService()

        #expect(!service.permanentlyDeleteTrashedMemo(fixture.memo))
        #expect(FileManager.default.fileExists(atPath: fixture.storedFile.path))
        #expect(service.lastError != nil)
    }

    @MainActor
    @Test func permanentRecordingDeleteRemovesInRootMemo() async throws {
        let fixture = try RecordingTrashFixture(symlinkedParent: false)
        defer { fixture.cleanUp() }
        let service = VoiceMemoService()

        #expect(service.permanentlyDeleteTrashedMemo(fixture.memo))
        #expect(!FileManager.default.fileExists(atPath: fixture.storedFile.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.projectFolder.path))
    }

    @MainActor
    @Test func aRecordingsFailureIsShownAndExpiryWaitsForIt() async throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TrashLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // A memo root that is not a folder cannot be scanned.
        let memosRoot = scratch.appendingPathComponent("voice-memos")
        try Data([0]).write(to: memosRoot)
        let library = RecordingLibrary(memosRoot: memosRoot, trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "TrashLifecycle-\(scratch.lastPathComponent)")!)
        container.mainContext.insert(TrashedSongProject(id: "expired", title: "Old", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1),
                                                        deletedAt: Date(timeIntervalSince1970: 2), deleteAfter: Date(timeIntervalSince1970: 3)))
        try container.mainContext.save()

        let viewModel = EditorViewModel(recordingLibrary: library)
        viewModel.modelContext = container.mainContext
        await viewModel.recordingsLaunchTask?.value

        #expect(viewModel.recordingListsSuspended)
        // Nothing plays while the recordings cannot be checked.
        #expect(!viewModel.isPlayableRecording(memosRoot.appendingPathComponent("song/take.m4a")))
        #expect(viewModel.errorMessage?.hasPrefix("Couldn't bring your recordings up to date") == true)
        #expect(try Self.fetchTrash(container.mainContext).map(\.id) == ["expired"])
        #expect(try Self.fetchDeletions(container.mainContext).isEmpty)
        // The permanent-delete path waits too (A33).
        let trashed = try #require(Self.fetchTrash(container.mainContext).first)
        #expect(!viewModel.permanentlyDeleteTrashedProject(trashed))
        #expect(try Self.fetchTrash(container.mainContext).map(\.id) == ["expired"])
        #expect(try Self.fetchDeletions(container.mainContext).isEmpty)
    }

    @MainActor
    @Test func aRecordingAWinningDeletionCoversIsNotPlayable() async throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Playable-\(UUID().uuidString)", isDirectory: true)
        let library = RecordingLibrary(memosRoot: scratch.appendingPathComponent("voice-memos", isDirectory: true),
                                       trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "Playable-\(scratch.lastPathComponent)")!)
        let context = container.mainContext
        let oldId = UUID().uuidString.lowercased(), newId = UUID().uuidString.lowercased()
        context.insert(Recording(id: oldId, projectId: "song", displayName: "old.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10)))
        context.insert(Recording(id: newId, projectId: "song", displayName: "new.m4a", audio: Data([2]), recordedAt: Date(timeIntervalSince1970: 90)))
        try context.save()
        let viewModel = EditorViewModel(recordingLibrary: library)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let old = library.memosRoot.appendingPathComponent("song/\(oldId).m4a")
        let new = library.memosRoot.appendingPathComponent("song/\(newId).m4a")
        #expect(viewModel.isPlayableRecording(old) && viewModel.isPlayableRecording(new))

        // A song deletion at 50 s wins against the older take only.
        context.insert(SyncDeletionRecord(projectId: "song", deletedAt: 50_000))
        try context.save()
        #expect(!viewModel.isPlayableRecording(old) && viewModel.isPlayableRecording(new))

        // A file waiting to move to quarantine is not played either.
        try RecordingFiles.setPendingQuarantine([RecordingFiles.canonicalPath(new)], for: library.memosRoot)
        #expect(!viewModel.isPlayableRecording(new))
    }

    @MainActor
    @Test func playbackStopsBeforeItsFileMoves() async throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("StopBeforeMove-\(UUID().uuidString)", isDirectory: true)
        let library = RecordingLibrary(memosRoot: scratch.appendingPathComponent("voice-memos", isDirectory: true),
                                       trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "StopBeforeMove-\(scratch.lastPathComponent)")!)
        let legacy = library.memosRoot.appendingPathComponent("song/long.m4a")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Far longer than the test: it cannot finish on its own.
        try AudioFixtures.long(seconds: 120, at: legacy)
        let viewModel = EditorViewModel(recordingLibrary: library)
        viewModel.modelContext = container.mainContext
        await viewModel.recordingsLaunchTask?.value
        let row = try #require(container.mainContext.fetch(FetchDescriptor<Recording>()).first)
        let url = try #require(row.fileURL(memosRoot: library.memosRoot, trashRoot: library.trashRoot))
        #expect(url.lastPathComponent == "\(row.id).m4a" && row.displayName == "long.m4a")

        viewModel.voiceMemoService.togglePlayback(url: url)
        for _ in 0..<50 where !viewModel.voiceMemoService.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        #expect(viewModel.voiceMemoService.isPlaying)

        var atBoundary: [(playing: Bool, fileStillThere: Bool)] = []
        library.atMoveBoundary = { file in
            atBoundary.append((viewModel.voiceMemoService.isPlaying, FileManager.default.fileExists(atPath: file.path)))
        }
        _ = viewModel.voiceMemoService.trashMemo(at: url, projectId: "song")

        #expect(atBoundary.count == 1 && atBoundary.first?.playing == false && atBoundary.first?.fileStillThere == true)
        #expect(!viewModel.voiceMemoService.isPlaying && !FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    private static func libraryViewModel(_ name: String) async throws -> (viewModel: EditorViewModel, library: RecordingLibrary, context: ModelContext, container: ModelContainer) {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let library = RecordingLibrary(memosRoot: scratch.appendingPathComponent("voice-memos", isDirectory: true),
                                       trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "\(name)-\(scratch.lastPathComponent)")!)
        return (EditorViewModel(recordingLibrary: library), library, container.mainContext, container)
    }

    @MainActor
    @Test func permanentDeletionNeedsTheCompleteCheckAndTheBytesThereNow() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("DeleteGate")
        _ = container
        let trashFile = library.trashRoot.appendingPathComponent("song/\(Date().epochMilliseconds)__take.m4a")
        try FileManager.default.createDirectory(at: trashFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: trashFile)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let trashed = try #require(library.trashedRecordings(in: context).first)
        let trashFileNow = trashed.url
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)

        // An unreadable move record: nothing is deleted.
        let record = RecordingFiles.quarantineRoot(for: library.memosRoot).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: record)
        #expect(!viewModel.permanentlyDeleteTrashedMemo(trashed))
        try FileManager.default.removeItem(at: record)

        // Other bytes in the row's Trash file: nothing is deleted either.
        try Data([9]).write(to: trashFileNow)
        #expect(!viewModel.permanentlyDeleteTrashedMemo(trashed))
        #expect(FileManager.default.fileExists(atPath: trashFileNow.path))
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
    }

    @MainActor
    @Test func aSongIsNotDeletedWhileItsFolderHoldsUncheckedBytes() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("SongGate")
        _ = container
        context.insert(TrashedSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1), deletedAt: Date()))
        try context.save()
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        // A file that appeared after the last check.
        let stray = library.memosRoot.appendingPathComponent("song/new.m4a")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([3]).write(to: stray)
        let trashed = try #require(context.fetch(FetchDescriptor<TrashedSongProject>()).first)

        #expect(!viewModel.permanentlyDeleteTrashedProject(trashed))
        #expect(FileManager.default.fileExists(atPath: stray.path))
        #expect(try context.fetch(FetchDescriptor<TrashedSongProject>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
    }

    @MainActor
    @Test func launchTimeDeletionsKeepSongsForIdTombstonesButNotTimelessSongs() async throws {
        let (viewModel, _, context, container) = try await Self.libraryViewModel("LaunchDeletions")
        _ = container
        context.insert(SongProject(id: "kept", title: "Kept", updatedAt: Date(timeIntervalSince1970: 50)))
        context.insert(SongProject(id: "timeless", title: "Timeless", updatedAt: Date(timeIntervalSince1970: 0)))
        context.insert(SyncRecordingDeletion(projectId: "kept", recordingId: "a-take", fileName: "", deletedAt: 4_000_000_000_000))
        context.insert(SyncDeletionRecord(projectId: "timeless", deletedAt: 1_000))
        try context.save()
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        // A recording's tombstone never removes its song; a song tombstone beats a repaired time (A38).
        #expect(try context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["kept"])
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.projectId) == ["timeless"])
    }

    @MainActor
    @Test func aTrashedSongWithoutATimeGetsItsFullRetentionAtLaunch() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("ZeroTrash")
        _ = container
        // As iCloud can deliver it: no deletion time, so a 1970 deadline.
        let zero = Date(timeIntervalSince1970: 0)
        // A fresh id: first-seen times are kept in the app's settings across runs.
        let songId = "old-\(UUID().uuidString)"
        context.insert(TrashedSongProject(id: songId, title: "Old", lyrics: "", theme: "", updatedAt: zero, deletedAt: zero,
                                          deleteAfter: zero.addingTimeInterval(trashRetentionInterval)))
        // A recording in the recordings Trash with no Trash time either.
        let id = UUID().uuidString.lowercased()
        let take = Recording(id: id, projectId: "song", displayName: "take.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10))
        take.trashedAt = zero
        context.insert(take)
        try context.save()
        let before = Date()
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        let row = try #require(context.fetch(FetchDescriptor<TrashedSongProject>()).first)
        #expect(row.deletedAt >= before.addingTimeInterval(-1) && row.trashedAtRepaired && row.precedenceRepaired)
        #expect(row.deleteAfter == row.deletedAt.addingTimeInterval(trashRetentionInterval))
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
        let trashed = try library.trashedRecordings(in: context)
        #expect(trashed.map(\.recordingId) == [id] && trashed[0].deleteAfter > Date().addingTimeInterval(trashRetentionInterval - 60))
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
    }

    @MainActor
    @Test func aFirstLaunchFromFilesAloneKeepsAZeroTimeTrashRecording() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("ZeroTrashFile")
        _ = container
        // Only a file on disk: a Trash name with no time, and no file date either.
        let file = library.trashRoot.appendingPathComponent("song/0__take.m4a")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([4]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        let before = Date().addingTimeInterval(-1)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(try #require(row.trashedAt) >= before && row.displayName == "take.m4a")
        #expect(FileManager.default.fileExists(atPath: library.trashRoot.appendingPathComponent("song/\(row.id).m4a").path))
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
    }

    @MainActor
    @Test func aLaunchTombstoneIsComparedWithTheTrashDeletionTimeOnly() async throws {
        let (viewModel, _, context, container) = try await Self.libraryViewModel("TrashTombstone")
        _ = container
        let trash = TrashedSongProject(id: "t", title: "T", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 300), deletedAt: Date(timeIntervalSince1970: 100))
        trash.precedenceRepaired = true
        context.insert(trash)
        context.insert(SyncDeletionRecord(projectId: "t", deletedAt: 200_000))
        try context.save()
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        #expect(try context.fetch(FetchDescriptor<TrashedSongProject>()).isEmpty)
    }

    @MainActor
    @Test func anUnfinishedOversizedTrashMoveNeverExpiresOtherBytesAtItsPlace() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("OversizedConflict")
        _ = container
        library.context = context
        try await library.reconcile(context: context)
        let take = Data(repeating: 1, count: Int(SyncRecording.maxBytes) + 1)
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).m4a")
        try take.write(to: staged)
        let live = try library.publishFinished(staged, projectId: "song", preferredName: "long.m4a", origin: .recorded)
        let id = try #require(RecordingFiles.storedId(of: live))
        // Its Trash move was journalled long ago; other audio of the same length sits at its Trash place.
        var entry = try #require(OversizedRecordings.read(for: library.memosRoot)[id])
        entry.trashedAt = 1_000
        entry.source = live.path
        entry.completed = false
        try OversizedRecordings.record(id: id, entry: entry, for: library.memosRoot)
        let place = library.trashRoot.appendingPathComponent("song/\(id).m4a")
        try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: Int(SyncRecording.maxBytes) + 1).write(to: place)

        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        viewModel.purgeExpiredTrashedProjects()

        #expect(try Data(contentsOf: place).first == 9 && FileManager.default.fileExists(atPath: live.path))
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
        #expect(Set(viewModel.recordingsNeedingAttention.map(\.lastPathComponent)) == ["\(id).m4a"])
        #expect(Set(viewModel.recordingsNeedingAttention.map { $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }) == ["voice-memos", "voice-memos-trash"])

        // Kept separately: the other audio gets its own id, and the move finishes.
        await viewModel.keepRecordingSeparately(place)
        #expect(try Data(contentsOf: place).first == 1 && !FileManager.default.fileExists(atPath: live.path))
        #expect(try OversizedRecordings.read(for: library.memosRoot).values.filter { $0.completed != false }.count == 2)
    }

    @MainActor
    @Test func expiryKeepsOnlyTheSongWhoseRecordingsAreNotAllChecked() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("PerSongExpiry")
        _ = container
        let long = Date(timeIntervalSince1970: 1_000)
        for id in ["clear", "blocked"] {
            context.insert(TrashedSongProject(id: id, title: id, lyrics: "", theme: "", updatedAt: long, deletedAt: long))
        }
        try context.save()
        // A file in the blocked song's folder that waits for its place (both files reported).
        let derived = RecordingBackupManifest.legacyRecordingId(projectId: "blocked", fileName: "a.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([1])))
        for (name, bytes) in [("a.m4a", Data([1])), ("\(derived).m4a", Data([9]))] {
            let url = library.memosRoot.appendingPathComponent("blocked/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        #expect(try context.fetch(FetchDescriptor<TrashedSongProject>()).map(\.id) == ["blocked"])
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.projectId) == ["clear"])
        #expect(FileManager.default.fileExists(atPath: library.memosRoot.appendingPathComponent("blocked/a.m4a").path))
    }

    @MainActor
    @Test func aReconcileMoveStopsPlaybackThroughTheHook() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("HookStop")
        _ = container
        let legacy = library.memosRoot.appendingPathComponent("song/long.m4a")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Far longer than the test: it cannot finish on its own.
        try AudioFixtures.long(seconds: 120, at: legacy)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        let url = try #require(row.fileURL(memosRoot: library.memosRoot, trashRoot: library.trashRoot))

        viewModel.voiceMemoService.togglePlayback(url: url)
        for _ in 0..<50 where !viewModel.voiceMemoService.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        #expect(viewModel.voiceMemoService.isPlaying)

        var atBoundary: [(playing: Bool, fileStillThere: Bool)] = []
        library.atMoveBoundary = { file in
            atBoundary.append((viewModel.voiceMemoService.isPlaying, FileManager.default.fileExists(atPath: file.path)))
        }
        // Trashed on another device: the reconcile moves the file itself,
        // with no VoiceMemoService call in between.
        row.trashedAt = Date()
        try context.save()
        #expect(await viewModel.reconcileRecordings())

        #expect(atBoundary.count == 1 && atBoundary.first?.playing == false && atBoundary.first?.fileStillThere == true)
        #expect(!viewModel.voiceMemoService.isPlaying)
        #expect(FileManager.default.fileExists(atPath: library.trashRoot.appendingPathComponent("song/\(row.id).m4a").path))
    }

    @MainActor
    private static func makeHarness() throws -> Harness {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel()
        viewModel.modelContext = container.mainContext
        return Harness(viewModel: viewModel, container: container)
    }

    @MainActor
    private static func fetchProjects(_ context: ModelContext) throws -> [SongProject] {
        var descriptor = FetchDescriptor<SongProject>(
            sortBy: [SortDescriptor(\.title)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    @MainActor
    private static func fetchTrash(_ context: ModelContext) throws -> [TrashedSongProject] {
        var descriptor = FetchDescriptor<TrashedSongProject>(
            sortBy: [SortDescriptor(\.id)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    @MainActor
    private static func fetchDeletions(_ context: ModelContext) throws -> [SyncDeletionRecord] {
        var descriptor = FetchDescriptor<SyncDeletionRecord>(
            sortBy: [SortDescriptor(\.projectId)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    @MainActor
    private struct Harness {
        let viewModel: EditorViewModel
        let container: ModelContainer

        var context: ModelContext {
            container.mainContext
        }
    }

    private struct RecordingTrashFixture {
        let memo: TrashedVoiceMemo
        let storedFile: URL
        let projectFolder: URL
        let scratch: URL

        init(symlinkedParent: Bool, deletedAt: Date = Date()) throws {
            let projectId = "trash-\(UUID().uuidString)"
            let projectFolder = RecordingFiles.trashFolder(for: projectId)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("TrashLifecycleTests-\(UUID().uuidString)", isDirectory: true)
            let deletedAtMs = Int(deletedAt.timeIntervalSince1970 * 1000)
            let storedName = "\(deletedAtMs)\(RecordingFiles.trashNameSeparator)take.m4a"

            try FileManager.default.createDirectory(
                at: RecordingFiles.memosTrashRoot(),
                withIntermediateDirectories: true
            )

            let storedFile: URL
            if symlinkedParent {
                let outside = scratch.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: projectFolder, withDestinationURL: outside)
                storedFile = outside.appendingPathComponent(storedName)
            } else {
                try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
                storedFile = projectFolder.appendingPathComponent(storedName)
            }
            try Data("private recording".utf8).write(to: storedFile)

            self.memo = TrashedVoiceMemo(
                url: projectFolder.appendingPathComponent(storedName),
                projectId: projectId,
                originalName: "take.m4a",
                deletedAt: deletedAt
            )
            self.storedFile = storedFile
            self.projectFolder = projectFolder
            self.scratch = scratch
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: projectFolder)
            try? FileManager.default.removeItem(at: scratch)
        }
    }
}
