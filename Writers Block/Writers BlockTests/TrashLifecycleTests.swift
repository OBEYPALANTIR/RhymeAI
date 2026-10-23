import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct TrashLifecycleTests {

    @MainActor
    @Test func moveProjectToTrashClearsCurrentEditorAndCreatesTrashEntry() throws {
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
    @Test func moveProjectToTrashReplacesDuplicateTrashEntries() throws {
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
    @Test func restoreTrashedProjectReplacesExistingActiveProject() throws {
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
    @Test func restoreTrashedProjectCollapsesDuplicateActiveAndTrashRows() throws {
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
    @Test func purgeExpiredTrashedProjectsKeepsUnexpiredTrash() throws {
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
    @Test func permanentProjectDeletePersistsTombstoneBeforeRemovingTrash() throws {
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
    @Test func persistedTombstoneSuppressesStaleProjectOnRelaunch() throws {
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
    @Test func songEditedAfterItsTombstoneSurvivesRelaunch() throws {
        let harness = try Self.makeHarness()
        harness.context.insert(SongProject(id: "back", title: "Edited later", lyrics: "kept", updatedAt: Date(timeIntervalSince1970: 300)))
        harness.context.insert(SyncDeletionRecord(projectId: "back", deletedAt: 200_000))
        try harness.context.save()

        let relaunched = EditorViewModel()
        relaunched.modelContext = harness.context

        #expect(try Self.fetchProjects(harness.context).map(\.id) == ["back"])
    }

    @MainActor
    @Test func permanentRecordingDeleteRejectsSymlinkedTrashParent() throws {
        let fixture = try RecordingTrashFixture(symlinkedParent: true)
        defer { fixture.cleanUp() }
        let service = VoiceMemoService()

        #expect(!service.permanentlyDeleteTrashedMemo(fixture.memo))
        #expect(FileManager.default.fileExists(atPath: fixture.storedFile.path))
        #expect(service.lastError != nil)
    }

    @MainActor
    @Test func permanentRecordingDeleteRemovesInRootMemo() throws {
        let fixture = try RecordingTrashFixture(symlinkedParent: false)
        defer { fixture.cleanUp() }
        let service = VoiceMemoService()

        #expect(service.permanentlyDeleteTrashedMemo(fixture.memo))
        #expect(!FileManager.default.fileExists(atPath: fixture.storedFile.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.projectFolder.path))
    }

    @MainActor
    @Test func expiredRecordingPurgeRejectsSymlinkedTrashParent() throws {
        let deletedAt = Date().addingTimeInterval(-trashRetentionInterval - 60)
        let fixture = try RecordingTrashFixture(symlinkedParent: true, deletedAt: deletedAt)
        defer { fixture.cleanUp() }
        #expect(fixture.memo.url.resolvingSymlinksInPath() == fixture.storedFile.resolvingSymlinksInPath())

        RecordingFiles.purgeExpiredTrashedMemos(now: Date())

        #expect(FileManager.default.fileExists(atPath: fixture.storedFile.path))
    }

    @MainActor
    @Test func expiredRecordingPurgeRejectsEnumeratedSymlinkedFile() throws {
        let deletedAt = Date().addingTimeInterval(-trashRetentionInterval - 60)
        let fixture = try RecordingTrashFixture(symlinkedParent: false, deletedAt: deletedAt)
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.scratch, withIntermediateDirectories: true)
        let outsideFile = fixture.scratch.appendingPathComponent("outside.m4a")
        try FileManager.default.moveItem(at: fixture.storedFile, to: outsideFile)
        try FileManager.default.createSymbolicLink(at: fixture.memo.url, withDestinationURL: outsideFile)

        let discovered = RecordingFiles.trashedMemos().contains {
            $0.url.resolvingSymlinksInPath() == outsideFile.resolvingSymlinksInPath()
        }
        #expect(discovered)

        RecordingFiles.purgeExpiredTrashedMemos(now: Date())
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    @MainActor
    @Test func tombstoneRecordingCleanupRejectsSymlinkedTrashParent() throws {
        let fixture = try RecordingTrashFixture(symlinkedParent: true)
        defer { fixture.cleanUp() }
        let service = VoiceMemoService()

        service.deletePermanentRecordingFiles(
            projectId: fixture.memo.projectId,
            fileName: fixture.memo.originalName
        )

        #expect(FileManager.default.fileExists(atPath: fixture.storedFile.path))
        #expect(service.lastError != nil)
    }

    @MainActor
    @Test func aRecordingsFailureIsShownAndExpiryWaitsForIt() throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, Recording.self])
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

        #expect(viewModel.errorMessage?.hasPrefix("Couldn't bring your recordings up to date") == true)
        #expect(try Self.fetchTrash(container.mainContext).map(\.id) == ["expired"])
        #expect(try Self.fetchDeletions(container.mainContext).isEmpty)
    }

    @MainActor
    @Test func aRecordingAWinningDeletionCoversIsNotPlayable() throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Playable-\(UUID().uuidString)", isDirectory: true)
        let library = RecordingLibrary(memosRoot: scratch.appendingPathComponent("voice-memos", isDirectory: true),
                                       trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "Playable-\(scratch.lastPathComponent)")!)
        let context = container.mainContext
        context.insert(Recording(id: "old", projectId: "song", fileName: "old.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10)))
        context.insert(Recording(id: "new", projectId: "song", fileName: "new.m4a", audio: Data([2]), recordedAt: Date(timeIntervalSince1970: 90)))
        try context.save()
        let viewModel = EditorViewModel(recordingLibrary: library)
        viewModel.modelContext = context
        let old = library.memosRoot.appendingPathComponent("song/old.m4a")
        let new = library.memosRoot.appendingPathComponent("song/new.m4a")
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
    private static func makeHarness() throws -> Harness {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
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
