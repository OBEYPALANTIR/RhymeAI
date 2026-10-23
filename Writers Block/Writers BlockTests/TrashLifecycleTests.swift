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
        // Full retention from a time taken in this launch, whatever the runner's speed.
        #expect(trashed.map(\.recordingId) == [id])
        #expect(trashed[0].deleteAfter >= before.addingTimeInterval(trashRetentionInterval - 1)
            && trashed[0].deleteAfter <= Date().addingTimeInterval(trashRetentionInterval))
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

/// Round 13 audit regressions for expiry.
extension TrashLifecycleTests {
    /// BLOCKER 11 (T2.45): an expired Trash copy of a song that is also active and
    /// newer is resolved first: the stale copy goes, with no tombstone, and the
    /// song's recordings stay.
    @MainActor
    @Test func anExpiredTrashCopyOfANewerActiveSongWritesNoTombstone() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("StaleTrashCopy")
        _ = container
        let now = Date()
        context.insert(SongProject(id: "s", title: "Active", updatedAt: now))
        context.insert(TrashedSongProject(id: "s", title: "Old", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000),
                                          deletedAt: Date(timeIntervalSince1970: 2_000), deleteAfter: now.addingTimeInterval(-60)))
        try context.save()
        let memo = library.memosRoot.appendingPathComponent("s/take.m4a")
        try FileManager.default.createDirectory(at: memo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2, 2]).write(to: memo)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        viewModel.purgeExpiredTrashedProjects()

        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TrashedSongProject>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["s"])
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.memosRoot.appendingPathComponent("s").path).count == 1)
    }

    /// BLOCKER 10 (T2.44): an oversized Trash recording whose ledger time is zero
    /// gets a real time (persisted) and full retention; it is not expired at once.
    @MainActor
    @Test func anOversizedTrashRecordingWithAZeroTimeIsNotExpiredAtOnce() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("ZeroOversized")
        _ = container
        library.context = context
        try await library.reconcile(context: context)
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).m4a")
        try Data(repeating: 3, count: Int(SyncRecording.maxBytes) + 1).write(to: staged)
        let live = try library.publishFinished(staged, projectId: "song", preferredName: "long.m4a", origin: .recorded)
        let id = try #require(RecordingFiles.storedId(of: live))
        // An earlier build left it in the Trash with no time.
        let place = library.trashRoot.appendingPathComponent("song/\(id).m4a")
        try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: live, to: place)
        var entry = try #require(OversizedRecordings.read(for: library.memosRoot)[id])
        entry.trashedAt = 0
        entry.completed = true
        entry.source = nil
        try OversizedRecordings.record(id: id, entry: entry, for: library.memosRoot)
        let before = Date().addingTimeInterval(-1).epochMilliseconds

        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        viewModel.purgeExpiredTrashedProjects()

        #expect(FileManager.default.fileExists(atPath: place.path))
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
        let repaired = try #require(OversizedRecordings.read(for: library.memosRoot)[id])
        #expect(try #require(repaired.trashedAt) >= before && repaired.trashedAtRepaired == true)
    }
}

/// Launch-time work runs after the editor is usable (coordinator item 3).
extension TrashLifecycleTests {
    /// An edit typed into a song before the launch check applies a stored tombstone
    /// is saved first and stands against it; nothing typed is lost.
    @MainActor
    @Test func anEditTypedBeforeLaunchDeletionsRunIsKept() async throws {
        let (viewModel, _, context, container) = try await Self.libraryViewModel("LaunchRace")
        _ = container
        let song = SongProject(id: "s", title: "Song", lyrics: "old line", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000))
        context.insert(song)
        context.insert(SyncDeletionRecord(projectId: "s", deletedAt: 2_000_000))
        try context.save()

        // The launch check is started but has not run yet (it waits for the main actor).
        viewModel.modelContext = context
        viewModel.loadProject(song)
        viewModel.lyrics = "typed at launch"
        viewModel.triggerAutoSave()
        await viewModel.recordingsLaunchTask?.value

        let kept = try #require(try context.fetch(FetchDescriptor<SongProject>()).first { $0.id == "s" })
        #expect(kept.lyrics == "typed at launch")
        #expect(viewModel.currentProjectId == "s" && viewModel.lyrics == "typed at launch")
    }

    /// A41: a song a stored tombstone removes at launch while its time is a repair is
    /// kept in the song recovery folder first.
    @MainActor
    @Test func aRepairedSongRemovedAtLaunchIsKeptInTheRecoveryFolder() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("LaunchRepaired")
        _ = container
        let song = SongProject(id: "r", title: "Repaired", lyrics: "keep me", theme: "", updatedAt: Date(timeIntervalSince1970: 9_000))
        song.precedenceRepaired = true
        context.insert(song)
        context.insert(SyncDeletionRecord(projectId: "r", deletedAt: 2_000_000))
        try context.save()

        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        #expect(try context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(try SongRecoveryStore.all(memosRoot: library.memosRoot).map { $0.project?.lyrics } == ["keep me"])
    }
}

/// Round 14 regressions.
extension TrashLifecycleTests {
    /// BLOCKER 1 (T2.45): an expired Trash copy of a song is not expired while a
    /// newer Trash copy of the same id is not due; the song's recordings stay.
    @MainActor
    @Test func anOlderExpiredTrashCopyDoesNotExpireANewerOne() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("TwoTrashCopies")
        _ = container
        let now = Date()
        context.insert(TrashedSongProject(id: "s", title: "Old", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000),
                                          deletedAt: now.addingTimeInterval(-trashRetentionInterval - 60), deleteAfter: now.addingTimeInterval(-60)))
        context.insert(TrashedSongProject(id: "s", title: "New", lyrics: "newer words", theme: "", updatedAt: now.addingTimeInterval(-10),
                                          deletedAt: now.addingTimeInterval(-5), deleteAfter: now.addingTimeInterval(trashRetentionInterval - 5)))
        try context.save()
        let memo = library.memosRoot.appendingPathComponent("s/take.m4a")
        try FileManager.default.createDirectory(at: memo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([3, 3]).write(to: memo)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        viewModel.purgeExpiredTrashedProjects()

        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TrashedSongProject>()).contains { $0.lyrics == "newer words" })
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.audio) == [Data([3, 3])])
    }

    /// BLOCKER 3: when the open song's edit cannot be saved before a launch-time
    /// deletion, nothing is deleted and the editor keeps the edit; a later save works.
    @MainActor
    @Test func aLaunchDeletionWaitsWhenTheOpenEditCannotBeSaved() async throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchSaveFails-\(UUID().uuidString)", isDirectory: true)
        let library = RecordingLibrary(memosRoot: scratch.appendingPathComponent("voice-memos", isDirectory: true),
                                       trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "LaunchSaveFails-\(scratch.lastPathComponent)")!)
        // Only the next save fails (the draft's); every later one works, so a deletion
        // that went ahead anyway would be saved.
        let failSaves = HookBox(false)
        let viewModel = EditorViewModel(recordingLibrary: library, saveModelContext: { context in
            if failSaves.value {
                failSaves.value = false
                throw CocoaError(.fileWriteUnknown)
            }
            try context.save()
        })
        let context = container.mainContext
        let song = SongProject(id: "s", title: "Song", lyrics: "old line", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000))
        context.insert(song)
        context.insert(SyncDeletionRecord(projectId: "s", deletedAt: 2_000_000))
        try context.save()

        viewModel.modelContext = context
        viewModel.loadProject(song)
        viewModel.lyrics = "typed at launch"
        failSaves.value = true
        await viewModel.recordingsLaunchTask?.value

        #expect(try context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["s"])
        #expect(viewModel.currentProjectId == "s" && viewModel.lyrics == "typed at launch")
        #expect(viewModel.flushCurrentDraft())
        #expect(try context.fetch(FetchDescriptor<SongProject>()).first?.lyrics == "typed at launch")
    }

    /// BLOCKER 4 (T5.24): repairing the records never gives a tombstone a time: a
    /// tombstone with none stays (recordings stay paused) and deletes nothing.
    @MainActor
    @Test func repairingRecordsNeverDeletesALiveSongOrRecording() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("RepairNoAuthority")
        _ = container
        context.insert(SongProject(id: "s", title: "Live", lyrics: "keep", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000)))
        try context.save()
        let memo = library.memosRoot.appendingPathComponent("s/take.m4a")
        try FileManager.default.createDirectory(at: memo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([5]).write(to: memo)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let recordingId = try #require(try context.fetch(FetchDescriptor<Recording>()).first).id
        // Tombstones whose time was lost (valid ids, no time).
        context.insert(SyncDeletionRecord(projectId: "s", deletedAt: 0))
        context.insert(SyncRecordingDeletion(projectId: "s", recordingId: recordingId, fileName: "take.m4a", deletedAt: 0))
        try context.save()

        await viewModel.repairRecordingRecords()
        viewModel.purgeExpiredTrashedProjects()

        #expect(try context.fetch(FetchDescriptor<SongProject>()).map(\.lyrics) == ["keep"])
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.id) == [recordingId])
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletedAt) == [0])
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).map(\.deletedAt) == [0])
        #expect(try Data(contentsOf: library.memosRoot.appendingPathComponent("s/\(recordingId).m4a")) == Data([5]))
        // Only what those tombstones name is held back; the recordings are not paused.
        #expect(!viewModel.recordingRecordsDamaged)
        #expect(viewModel.recordingNotes.contains { $0.contains("no time") && $0.contains(recordingId) })
        #expect(!viewModel.isPlayableRecording(library.memosRoot.appendingPathComponent("s/\(recordingId).m4a")))
    }
}

/// Round 14: times that arrive after launch, damaged records and reports.
extension TrashLifecycleTests {
    /// T2.50: a Trash entry delivered after launch with no deletion time is given one
    /// (kept, as a repair) before expiry looks at it; it is not expired at once.
    @MainActor
    @Test func aTrashEntryArrivingWithNoTimeIsFixedBeforeExpiry() async throws {
        let (viewModel, _, context, container) = try await Self.libraryViewModel("LateTrashTime")
        _ = container
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let before = Date().addingTimeInterval(-1)
        // A fresh id: the editor's first-seen record lives in shared settings.
        context.insert(TrashedSongProject(id: "late-\(UUID().uuidString)", title: "Late", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1),
                                          deletedAt: Date(timeIntervalSince1970: 0), deleteAfter: Date(timeIntervalSince1970: 0)))
        try context.save()

        viewModel.purgeExpiredTrashedProjects()

        let kept = try #require(try context.fetch(FetchDescriptor<TrashedSongProject>()).first)
        #expect(kept.trashedAtRepaired && kept.deletedAt >= before)
        #expect(kept.deleteAfter == kept.deletedAt.addingTimeInterval(trashRetentionInterval))
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
    }

    /// T2.52: an oversized Trash record whose time is lost after launch is fixed and
    /// kept when listed; its file is not expired.
    @MainActor
    @Test func anOversizedTrashRecordLosingItsTimeAfterLaunchIsNotExpired() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("LateLedgerTime")
        _ = container
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).m4a")
        try Data(repeating: 2, count: Int(SyncRecording.maxBytes) + 1).write(to: staged)
        let live = try library.publishFinished(staged, projectId: "song", preferredName: "long.m4a", origin: .recorded)
        let id = try #require(RecordingFiles.storedId(of: live))
        let trashed = try library.trashRecording(at: live, trashedAt: Date())
        var entry = try #require(OversizedRecordings.read(for: library.memosRoot)[id])
        entry.trashedAt = 0
        try OversizedRecordings.record(id: id, entry: entry, for: library.memosRoot)

        viewModel.purgeExpiredTrashedProjects()

        #expect(FileManager.default.fileExists(atPath: trashed.url.path))
        let fixed = try #require(OversizedRecordings.read(for: library.memosRoot)[id])
        #expect((fixed.trashedAt ?? 0) > 0 && fixed.trashedAtRepaired == true)
    }

    /// T2.50: a recordings Trash row delivered after launch with no Trash time is
    /// fixed and kept when listed; it is not expired at once.
    @MainActor
    @Test func aTrashRowArrivingWithNoTimeIsFixedBeforeExpiry() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("LateRowTrashTime")
        _ = container
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).m4a")
        try Data([7, 7]).write(to: staged)
        let live = try library.publishFinished(staged, projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let trashed = try library.trashRecording(at: live, trashedAt: Date())
        let row = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        row.trashedAt = Date(timeIntervalSince1970: 0)
        try context.save()

        viewModel.purgeExpiredTrashedProjects()

        #expect(FileManager.default.fileExists(atPath: trashed.url.path))
        #expect(row.trashedAtRepaired && (row.trashedAt?.epochMilliseconds ?? 0) > 0 && !context.hasChanges)
    }

    /// T2.55: a row delivered without a time is fixed and kept when its playability
    /// is judged; as a repair it loses to a tombstone (A41) and does not play.
    @MainActor
    @Test func aRowWithoutATimeIsFixedWhenJudgedForPlayback() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("PlayUnknownTime")
        _ = container
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).m4a")
        try Data([1, 2]).write(to: staged)
        let live = try library.publishFinished(staged, projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let row = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        row.uploadedAt = nil
        row.recordedAt = Date(timeIntervalSince1970: 0)
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: row.id, fileName: "take.m4a", deletedAt: 1_000))
        try context.save()

        #expect(!viewModel.isPlayableRecording(live))

        #expect(row.precedenceRepaired && row.precedenceTime.epochMilliseconds > 0)
        #expect(!context.hasChanges, "the fixed time was saved")
    }

    /// T3.36: a damaged record of the editor's first-seen times is set aside and
    /// reported; the song still gets a time.
    @MainActor
    @Test func aDamagedEditorTimeRecordIsSetAsideAndReported() async throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let defaults = UserDefaults(suiteName: "EditorTimes-\(UUID().uuidString)")!
        defaults.set("garbage", forKey: "editor-first-seen-times")
        let viewModel = EditorViewModel(defaults: defaults)
        let context = container.mainContext
        let song = SongProject(id: "s", title: "S", updatedAt: Date(timeIntervalSince1970: 0))
        context.insert(song)
        try context.save()

        viewModel.modelContext = context

        #expect(defaults.string(forKey: "editor-first-seen-times.damaged") == "garbage")
        #expect(viewModel.errorMessage?.contains("damaged") == true)
        #expect(song.precedenceRepaired && song.updatedAt.epochMilliseconds > 0)
    }

    /// T5.2: a damaged move record stops the check; Repair sets it aside (kept) and
    /// the check runs again with every file where it was.
    @MainActor
    @Test func repairingADamagedMoveRecordLetsTheCheckRunAgain() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("RepairMoves")
        _ = container
        let memo = library.memosRoot.appendingPathComponent("song/take.m4a")
        try FileManager.default.createDirectory(at: memo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([4]).write(to: memo)
        let record = RecordingFiles.quarantineRoot(for: library.memosRoot).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"quarantine\": 7}".utf8).write(to: record)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        #expect(viewModel.recordingRecordsDamaged)

        await viewModel.repairRecordingRecords()

        #expect(!viewModel.recordingRecordsDamaged)
        let aside = try FileManager.default.contentsOfDirectory(atPath: record.deletingLastPathComponent().path).filter { $0.hasPrefix("pending-moves.damaged-") }
        #expect(aside.count == 1)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.audio) == [Data([4])])
    }

    /// T5.8, T5.9: files left waiting and files that are not recordings are named in
    /// Settings by where they are kept; checking again takes the waiting ones in.
    @MainActor
    @Test func waitingAndUnrecognizedFilesAreNamedByLocationAndCheckingAgainTakesThemIn() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("Deferred")
        _ = container
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        library.adoptionBudget = 1
        for index in 0..<70 {
            let url = library.memosRoot.appendingPathComponent("song/take-\(index).m4a")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([UInt8(index), 1]).write(to: url)
        }
        try Data("notes".utf8).write(to: library.memosRoot.appendingPathComponent("song/readme.txt"))
        // One run takes at most 64 passes of one file each: six are left waiting.
        _ = await viewModel.reconcileRecordings()
        let first = viewModel.recordingNotes.joined(separator: " ")
        #expect(first.contains("voice-memos/song/readme.txt"))
        #expect(first.contains("Waiting to be read into the library: voice-memos/song/take-"))

        for _ in 0..<5 where try context.fetch(FetchDescriptor<Recording>()).count < 70 { _ = await viewModel.reconcileRecordings() }

        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 70)
        #expect(!viewModel.recordingNotes.joined().contains("Waiting to be read"))
    }
}


/// Round 15.
extension TrashLifecycleTests {
    /// BLOCKER 1: with two active copies of a song, the newer one is what an expired
    /// Trash entry meets: it stands, in either fetch order; nothing is tombstoned and
    /// the song's recording stays.
    @MainActor
    @Test(arguments: [false, true])
    func aNewerActiveCopyDefeatsAnExpiredTrashEntry(newerFirst: Bool) async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("ActiveCopies")
        _ = container
        let now = Date()
        let deletedAt = now.addingTimeInterval(-trashRetentionInterval - 600)
        let older = SongProject(id: "s", title: "Old", lyrics: "older words", theme: "", updatedAt: deletedAt.addingTimeInterval(-60))
        let newer = SongProject(id: "s", title: "New", lyrics: "newer words", theme: "", updatedAt: deletedAt.addingTimeInterval(60))
        for song in newerFirst ? [newer, older] : [older, newer] { context.insert(song) }
        context.insert(TrashedSongProject(id: "s", title: "Binned", lyrics: "", theme: "", updatedAt: deletedAt.addingTimeInterval(-120),
                                          deletedAt: deletedAt, deleteAfter: deletedAt.addingTimeInterval(trashRetentionInterval)))
        try context.save()
        let memo = library.memosRoot.appendingPathComponent("s/take.m4a")
        try FileManager.default.createDirectory(at: memo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9, 1]).write(to: memo)
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        viewModel.purgeExpiredTrashedProjects()

        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TrashedSongProject>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SongProject>()).contains { $0.lyrics == "newer words" })
        let row = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        #expect(try Data(contentsOf: library.memosRoot.appendingPathComponent("s/\(row.id).m4a")) == Data([9, 1]))
    }

    /// T2.50: scheduling the next expiry (here after a song goes to Trash, with no
    /// purge) fixes and keeps a Trash time that arrived missing.
    @MainActor
    @Test func schedulingTheNextExpiryFixesAMissingTrashTime() async throws {
        let (viewModel, _, context, container) = try await Self.libraryViewModel("ScheduleTimes")
        _ = container
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let lateId = "late-\(UUID().uuidString)"
        context.insert(TrashedSongProject(id: lateId, title: "Late", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1),
                                          deletedAt: Date(timeIntervalSince1970: 0), deleteAfter: Date(timeIntervalSince1970: 0)))
        let other = SongProject(id: "other-\(UUID().uuidString)", title: "Other", lyrics: "x", theme: "", updatedAt: Date())
        context.insert(other)
        try context.save()
        let before = Date().addingTimeInterval(-1)

        #expect(viewModel.moveProjectToTrash(other))

        let late = try #require(try context.fetch(FetchDescriptor<TrashedSongProject>()).first { $0.id == lateId })
        #expect(late.trashedAtRepaired && late.deletedAt >= before && !context.hasChanges)
    }

    /// T5.24: a tombstone without a time holds only what it names (kept, not shown or
    /// played); other tombstones apply; a tombstone of the same recording with a time
    /// supersedes it and then applies.
    @MainActor
    @Test func anUndatedTombstoneHoldsOnlyWhatItNamesUntilADatedOneArrives() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("Undated")
        _ = container
        for (song, bytes) in [("a", Data([1])), ("b", Data([2]))] {
            context.insert(SongProject(id: song, title: song, lyrics: song, theme: "", updatedAt: Date(timeIntervalSince1970: 1_000)))
            let url = library.memosRoot.appendingPathComponent("\(song)/take.m4a")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        // A tombstone of song "a"'s recording without a time, and one of song "b" with one.
        let heldId = RecordingBackupManifest.legacyRecordingId(projectId: "a", fileName: "take.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([1])))
        context.insert(SyncRecordingDeletion(projectId: "a", recordingId: heldId, fileName: "take.m4a", deletedAt: 0))
        context.insert(SyncDeletionRecord(projectId: "b", deletedAt: Date().epochMilliseconds + 60_000))
        try context.save()

        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value

        #expect(try context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["a"])
        #expect(!viewModel.recordingRecordsDamaged)
        // Song "b" and its recording went; "a"'s recording is kept but not listed.
        #expect(try library.liveRecordings(in: context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.id) == [heldId])
        #expect(try Data(contentsOf: library.memosRoot.appendingPathComponent("a/\(heldId).m4a")) == Data([1]))
        #expect(viewModel.recordingNotes.contains { $0.contains(heldId) })

        // A tombstone of the same recording with a time arrives (here directly, as
        // Drive or Import store it): it supersedes the undated one and applies.
        try DeletionStore.upsert(SyncDeletion(projectId: "a", recordingId: heldId, fileName: "take.m4a", deletedAt: Date().epochMilliseconds), in: context)
        try context.save()
        #expect(try DeletionStore.undated(in: context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).filter { $0.recordingId == heldId }.count == 1)
        #expect(await viewModel.reconcileRecordings())
        #expect(!FileManager.default.fileExists(atPath: library.memosRoot.appendingPathComponent("a/\(heldId).m4a").path))
        #expect(!viewModel.recordingNotes.contains { $0.contains(heldId) })
    }
}


/// Round 16.
extension TrashLifecycleTests {
    /// The state for an expired Trash entry (recorded deletion time) that beats two
    /// repaired active copies with other words, and a recording with a repaired time.
    @MainActor
    private func resolvingExpiry(_ name: String, blockRecovery: Bool = false) async throws -> (viewModel: EditorViewModel, library: RecordingLibrary, context: ModelContext, container: ModelContainer, recordingId: String) {
        let (viewModel, library, context, container) = try await Self.libraryViewModel(name)
        let now = Date()
        let deletedAt = now.addingTimeInterval(-trashRetentionInterval - 600)
        for (lyrics, offset) in [("first repaired words", 60.0), ("second repaired words", 120.0)] {
            let song = SongProject(id: "s", title: "Active", lyrics: lyrics, theme: "", updatedAt: deletedAt.addingTimeInterval(offset))
            song.precedenceRepaired = true
            context.insert(song)
        }
        context.insert(TrashedSongProject(id: "s", title: "Binned", lyrics: "binned words", theme: "", updatedAt: deletedAt.addingTimeInterval(-60),
                                          deletedAt: deletedAt, deleteAfter: deletedAt.addingTimeInterval(trashRetentionInterval)))
        // A recording with no time: repaired when first seen, so the deletion beats it (A41).
        let take = Recording(projectId: "s", displayName: "take.m4a", audio: Data([7, 3, 7]), recordedAt: Date(timeIntervalSince1970: 0))
        take.uploadedAt = nil
        context.insert(take)
        try context.save()
        if blockRecovery {
            // The recovery folder cannot be made: a file stands at its path.
            let root = SongRecoveryStore.root(for: library.memosRoot)
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: root)
        }
        // The launch check runs expiry too.
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        return (viewModel, library, context, container, take.id)
    }

    /// BLOCKER 1: expiry that beats repaired active copies keeps each of them in the
    /// song recovery folder first, and moves the recording it removes to quarantine
    /// with its exact bytes; nothing is unlinked.
    @MainActor
    @Test func expiryKeepsTheRepairedCopiesItBeatsAndQuarantinesTheirRecording() async throws {
        let (viewModel, library, context, container, recordingId) = try await resolvingExpiry("ResolvingExpiry")
        _ = container
        let file = library.memosRoot.appendingPathComponent("s/\(recordingId).m4a")
        // The launch check already ran expiry; running it again changes nothing more.
        viewModel.purgeExpiredTrashedProjects()
        _ = await viewModel.reconcileRecordings()

        #expect(try context.fetch(FetchDescriptor<SongProject>()).isEmpty && context.fetch(FetchDescriptor<TrashedSongProject>()).isEmpty)
        let kept = try SongRecoveryStore.all(memosRoot: library.memosRoot)
        #expect(Set(kept.compactMap { $0.project?.lyrics }) == ["first repaired words", "second repaired words"])
        let quarantined = RecordingFiles.quarantineRoot(for: library.memosRoot).appendingPathComponent("s/\(recordingId).m4a")
        #expect((try? Data(contentsOf: quarantined)) == Data([7, 3, 7]), "its exact bytes are kept in quarantine")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// BLOCKER 1: when the recovery copy cannot be written, expiry changes nothing.
    @MainActor
    @Test func expiryChangesNothingWhenTheRecoveryCopyFails() async throws {
        let (viewModel, library, context, container, recordingId) = try await resolvingExpiry("ResolvingExpiryFails", blockRecovery: true)
        _ = container

        viewModel.purgeExpiredTrashedProjects()

        #expect(try context.fetch(FetchDescriptor<SongProject>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<TrashedSongProject>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
        #expect(try Data(contentsOf: library.memosRoot.appendingPathComponent("s/\(recordingId).m4a")) == Data([7, 3, 7]))
    }

    /// SHOULD 3: a recording over the cap (no row) that is playing stops when a
    /// tombstone without a time for it arrives, and is not played again; it is kept.
    @MainActor
    @Test func playbackOfAHeldRecordingOverTheCapStops() async throws {
        let (viewModel, library, context, container) = try await Self.libraryViewModel("HeldPlayback")
        _ = container
        viewModel.modelContext = context
        await viewModel.recordingsLaunchTask?.value
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("large-\(UUID().uuidString).m4a")
        try AudioFixtures.large(at: staged)
        try #require(try RecordingFiles.facts(staged).size > SyncRecording.maxBytes)
        let live = try library.publishFinished(staged, projectId: "song", preferredName: "long.m4a", origin: .recorded)
        let id = try #require(RecordingFiles.storedId(of: live))
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        viewModel.voiceMemoService.togglePlayback(url: live)
        for _ in 0..<50 where !viewModel.voiceMemoService.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        try #require(viewModel.voiceMemoService.isPlaying)

        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "long.m4a", deletedAt: 0))
        try context.save()
        _ = await viewModel.reconcileRecordings()

        #expect(!viewModel.voiceMemoService.isPlaying)
        #expect(!viewModel.isPlayableRecording(live))
        #expect(FileManager.default.fileExists(atPath: live.path))
    }
}
