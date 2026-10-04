import Foundation
import SwiftData
import Testing
@testable import Writers_Block

/// Edits typed while a backup or restore holds the library must survive the app
/// being killed before the operation reconciles them. A "kill" here is an
/// operation that never returns, followed by a new view model on the same
/// store and recovery file.
@MainActor
struct DraftRecoveryTests {
    @Test func editsTypedDuringBackupSurviveKill() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        let service = GatedBackupService()
        let viewModel = harness.makeViewModel(service: service)
        viewModel.loadProject(project)

        Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()
        viewModel.lyrics = "typed during backup"
        viewModel.triggerAutoSave()
        #expect(try harness.projects().first?.lyrics == "saved A")

        let relaunched = harness.makeViewModel()

        let projects = try harness.projects()
        #expect(projects.count == 1)
        #expect(projects.first?.id == "song-a")
        #expect(projects.first?.lyrics == "typed during backup")
        #expect(relaunched.currentProjectId == "song-a")
        #expect(relaunched.lyrics == "typed during backup")
        #expect(!relaunched.showWelcome)
        #expect(!harness.recoveryCopyExists)
    }

    @Test func editsTypedDuringRestoreSurviveKillWithoutOverwritingRestoredSong() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        let service = GatedBackupService()
        // The restore applies a newer remote version of the open song, then stalls.
        service.onStart = { context in
            project.title = "Remote A"
            project.lyrics = "remote A"
            project.updatedAt = Date().addingTimeInterval(3_600)
            try context.save()
        }
        let viewModel = harness.makeViewModel(service: service)
        viewModel.loadProject(project)

        Task { await viewModel.restoreBackupNow() }
        try await service.waitUntilStarted()
        viewModel.lyrics = "typed during restore"
        viewModel.triggerAutoSave()

        let relaunched = harness.makeViewModel()

        var projects = try harness.projects()
        #expect(projects.count == 2)
        #expect(projects.first(where: { $0.id == "song-a" })?.lyrics == "remote A")
        let recovered = try #require(projects.first(where: { $0.id != "song-a" }))
        #expect(recovered.lyrics == "typed during restore")
        #expect(relaunched.currentProjectId == recovered.id)
        #expect(relaunched.lyrics == "typed during restore")
        #expect(!harness.recoveryCopyExists)

        // A second launch finds nothing left to recover.
        _ = harness.makeViewModel()
        projects = try harness.projects()
        #expect(projects.count == 2)
    }

    @Test func completedOperationLeavesNoRecoveryCopy() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        let service = GatedBackupService()
        let viewModel = harness.makeViewModel(service: service)
        viewModel.loadProject(project)

        let operation = Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()
        viewModel.lyrics = "typed during backup"
        viewModel.triggerAutoSave()
        #expect(harness.recoveryCopyExists)

        service.release()
        await operation.value

        #expect(!harness.recoveryCopyExists)
        let projects = try harness.projects()
        #expect(projects.count == 1)
        #expect(projects.first?.lyrics == "typed during backup")

        // Nothing is recovered a second time on the next launch.
        let relaunched = harness.makeViewModel()
        #expect(try harness.projects().count == 1)
        #expect(relaunched.currentProjectId == nil)
    }

    @Test func staleRecoveryCopyDoesNotOverwriteNewerSong() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        let service = GatedBackupService()
        let viewModel = harness.makeViewModel(service: service)
        viewModel.loadProject(project)

        Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()
        viewModel.lyrics = "old typed text"
        viewModel.triggerAutoSave()
        #expect(harness.recoveryCopyExists)

        // The stored song moves on after the recovery copy was written.
        project.lyrics = "newer stored text"
        project.updatedAt = Date().addingTimeInterval(60)
        try harness.context.save()

        _ = harness.makeViewModel()

        let projects = try harness.projects()
        #expect(projects.first(where: { $0.id == "song-a" })?.lyrics == "newer stored text")
        // The older text is kept as its own song rather than dropped.
        #expect(projects.count == 2)
        #expect(projects.first(where: { $0.id != "song-a" })?.lyrics == "old typed text")
        #expect(!harness.recoveryCopyExists)
    }

    @Test func recoveryCopyAlreadyInLibraryIsNotDuplicated() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        let service = GatedBackupService()
        let viewModel = harness.makeViewModel(service: service)
        viewModel.loadProject(project)

        Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()
        viewModel.lyrics = "typed during backup"
        viewModel.triggerAutoSave()
        #expect(harness.recoveryCopyExists)

        // The kill came after the edit reached the library but before the
        // recovery copy was removed.
        project.lyrics = "typed during backup"
        project.updatedAt = Date()
        try harness.context.save()

        let relaunched = harness.makeViewModel()

        #expect(try harness.projects().count == 1)
        #expect(relaunched.currentProjectId == nil)
        #expect(!harness.recoveryCopyExists)
    }

    @Test func recoveryCopyDoesNotOverwriteSongSavedLaterWithUnchangedText() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        try await harness.leaveRecoveryCopy(for: project, typing: "typed during backup")

        // Same text as when the copy was written, but saved after it.
        project.updatedAt = Date().addingTimeInterval(60)
        try harness.context.save()

        _ = harness.makeViewModel()

        let projects = try harness.projects()
        #expect(projects.count == 2)
        #expect(projects.first(where: { $0.id == "song-a" })?.lyrics == "saved A")
        #expect(projects.first(where: { $0.id != "song-a" })?.lyrics == "typed during backup")
        #expect(!harness.recoveryCopyExists)
    }

    @Test func failedRecoveryIsNotDeletedByLaterSavesOrBackups() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        try await harness.leaveRecoveryCopy(for: project, typing: "typed during backup")

        // The launch that should recover the text cannot save.
        var savesFail = true
        let service = GatedBackupService()
        service.release()
        let failedLaunch = harness.makeViewModel(service: service) { context in
            if savesFail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }
        #expect(failedLaunch.errorMessage != nil)
        #expect(try harness.projects().first?.lyrics == "saved A")
        #expect(harness.recoveryCopyExists)

        // The automatic backup runs with nothing pending in the editor, another
        // song is saved normally, and a manual backup completes. None of them
        // may remove the unrecovered copy.
        savesFail = false
        await failedLaunch.runCloudBackupOnBackgroundIfPossible()
        #expect(harness.recoveryCopyExists)
        failedLaunch.newProject()
        failedLaunch.lyrics = "another song"
        #expect(failedLaunch.flushCurrentDraft())
        await failedLaunch.backUpNow()
        failedLaunch.lyrics = "another song, edited"
        failedLaunch.triggerAutoSave()
        #expect(failedLaunch.flushCurrentDraft())
        #expect(harness.recoveryCopyExists)

        _ = harness.makeViewModel()

        #expect(try harness.projects().first(where: { $0.id == "song-a" })?.lyrics == "typed during backup")
        #expect(!harness.recoveryCopyExists)
    }

    @Test func recoveryIsSkippedForAnInMemoryLibrary() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        try await harness.leaveRecoveryCopy(for: project, typing: "typed during backup")
        let copy = try Data(contentsOf: harness.recoveryURL)

        // The fallback library used when the real one cannot be opened.
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let fallback = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let service = GatedBackupService()
        let degraded = EditorViewModel(
            keychainStore: InMemoryKeychainStore(), backupService: service,
            draftRecoveryURL: harness.recoveryURL
        )
        degraded.modelContext = fallback.mainContext
        #expect(try fallback.mainContext.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(degraded.currentProjectId == nil)

        // Typing during a backup in that session must not replace the copy either.
        Task { await degraded.backUpNow() }
        try await service.waitUntilStarted()
        degraded.lyrics = "typed in the fallback session"
        degraded.triggerAutoSave()
        #expect(try Data(contentsOf: harness.recoveryURL) == copy)

        _ = harness.makeViewModel()
        #expect(try harness.projects().first?.lyrics == "typed during backup")
        #expect(!harness.recoveryCopyExists)
    }

    @Test func unreadableRecoveryFileIsSetAsideWithoutBlockingLaunch() async throws {
        let harness = try RecoveryHarness()
        _ = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        try FileManager.default.createDirectory(
            at: harness.recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let garbage = Data("not a recovery record".utf8)
        try garbage.write(to: harness.recoveryURL)

        let viewModel = harness.makeViewModel()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.currentProjectId == nil)
        #expect(try harness.projects().map(\.lyrics) == ["saved A"])
        #expect(!harness.recoveryCopyExists)
        let kept = try harness.recoveryFolderFiles().filter { $0.lastPathComponent.hasPrefix("unreadable-") }
        #expect(kept.count == 1)
        #expect(try kept.first.map { try Data(contentsOf: $0) } == garbage)

        // It is not retried or duplicated on the next launch.
        _ = harness.makeViewModel()
        #expect(try harness.recoveryFolderFiles().count == 1)
    }

    @Test func identicalTwinSongDoesNotCauseRecoveryToBeDropped() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "Same", lyrics: "saved A")
        // An unrelated song that already has exactly the text about to be typed.
        _ = try harness.seedProject(id: "song-twin", title: "Same", lyrics: "typed during backup")
        try await harness.leaveRecoveryCopy(for: project, typing: "typed during backup")

        let relaunched = harness.makeViewModel()

        let projects = try harness.projects()
        #expect(projects.count == 2)
        #expect(projects.first(where: { $0.id == "song-a" })?.lyrics == "typed during backup")
        #expect(relaunched.currentProjectId == "song-a")
        #expect(!harness.recoveryCopyExists)
    }

    @Test func neverSavedDraftIsRecoveredAsItsOwnSongDespiteIdenticalTwin() async throws {
        let harness = try RecoveryHarness()
        _ = try harness.seedProject(id: "song-twin", title: "Untitled Song", lyrics: "new hook")
        let service = GatedBackupService()
        let viewModel = harness.makeViewModel(service: service)

        Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()
        viewModel.newProject()
        viewModel.lyrics = "new hook"
        viewModel.triggerAutoSave()
        #expect(harness.recoveryCopyExists)

        let relaunched = harness.makeViewModel()

        var projects = try harness.projects()
        #expect(projects.count == 2)
        let recovered = try #require(projects.first(where: { $0.id != "song-twin" }))
        #expect(recovered.lyrics == "new hook")
        #expect(relaunched.currentProjectId == recovered.id)
        #expect(!harness.recoveryCopyExists)

        _ = harness.makeViewModel()
        projects = try harness.projects()
        #expect(projects.count == 2)
    }

    @Test func cloudBackedLibraryRecoversAsSeparateSongInsteadOfUpdatingInPlace() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        try await harness.leaveRecoveryCopy(for: project, typing: "typed during backup")

        // The stored song still matches what the editor started from, but another
        // device's newer version may not have been downloaded yet.
        let relaunched = harness.makeViewModel(cloudBacked: true)

        let projects = try harness.projects()
        #expect(projects.count == 2)
        #expect(projects.first(where: { $0.id == "song-a" })?.lyrics == "saved A")
        let recovered = try #require(projects.first(where: { $0.id != "song-a" }))
        #expect(recovered.lyrics == "typed during backup")
        #expect(relaunched.currentProjectId == recovered.id)
        #expect(!harness.recoveryCopyExists)
    }

    @Test func recordingsFollowDraftRecoveredAfterRestoreDeletedTheSong() async throws {
        let harness = try RecoveryHarness()
        let audio = Data("take one".utf8)
        try await harness.leaveRecoveryCopyAfterRestoreDeletesSong(recording: audio, typing: "typed during restore")
        #expect(try harness.recordings(for: "song-a").isEmpty)
        #expect(try harness.stagedSnapshots().count == 1)

        let relaunched = harness.makeViewModel()

        let projects = try harness.projects()
        #expect(projects.count == 1)
        let recovered = try #require(projects.first)
        #expect(recovered.id != "song-a")
        #expect(recovered.lyrics == "typed during restore")
        #expect(relaunched.currentProjectId == recovered.id)
        #expect(try harness.recordings(for: recovered.id) == ["100.m4a": audio])
        #expect(try harness.stagedSnapshots().isEmpty)
        #expect(!harness.recoveryCopyExists)
    }

    @Test func recordingSnapshotIsKeptUntilTheRecoveredSongIsSaved() async throws {
        let harness = try RecoveryHarness()
        let audio = Data("take one".utf8)
        try await harness.leaveRecoveryCopyAfterRestoreDeletesSong(recording: audio, typing: "typed during restore")

        let failedLaunch = harness.makeViewModel { _ in throw CocoaError(.fileWriteUnknown) }

        #expect(failedLaunch.errorMessage != nil)
        #expect(try harness.projects().isEmpty)
        #expect(harness.recoveryCopyExists)
        let staged = try harness.stagedSnapshots()
        #expect(staged.count == 1)
        #expect(try staged.first.map { try Data(contentsOf: $0.appendingPathComponent("100.m4a")) } == audio)
        // The failed attempt leaves no recordings under a song that was not saved.
        #expect(try harness.recordingFolders().isEmpty)

        _ = harness.makeViewModel()

        let recovered = try #require(try harness.projects().first)
        #expect(recovered.lyrics == "typed during restore")
        #expect(try harness.recordings(for: recovered.id) == ["100.m4a": audio])
        #expect(try harness.stagedSnapshots().isEmpty)
    }

    @Test func unreferencedRecordingSnapshotIsRemovedOnlyWhenLiveCopiesExist() async throws {
        // Killed during a backup with nothing typed: the snapshot duplicates
        // recordings the song still has.
        let redundant = try RecoveryHarness()
        let kept = try redundant.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        try redundant.writeRecording(Data("take one".utf8), named: "100.m4a", projectId: "song-a")
        let service = GatedBackupService()
        let viewModel = redundant.makeViewModel(service: service)
        viewModel.loadProject(kept)
        Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()
        #expect(try redundant.stagedSnapshots().count == 1)
        #expect(!redundant.recoveryCopyExists)

        await redundant.makeViewModel().waitForRecordingSnapshotSweepForTesting()

        #expect(try redundant.stagedSnapshots().isEmpty)
        #expect(try redundant.recordings(for: "song-a").count == 1)

        // Killed during a restore that deleted the song, with nothing typed: the
        // snapshot is the only copy of the audio left on the device.
        let onlyCopy = try RecoveryHarness()
        try await onlyCopy.leaveRecoveryCopyAfterRestoreDeletesSong(recording: Data("take one".utf8), typing: nil)
        #expect(!onlyCopy.recoveryCopyExists)

        await onlyCopy.makeViewModel().waitForRecordingSnapshotSweepForTesting()

        let staged = try onlyCopy.stagedSnapshots()
        #expect(staged.count == 1)
        #expect(try staged.first.map { try Data(contentsOf: $0.appendingPathComponent("100.m4a")) } == Data("take one".utf8))
    }

    @Test func unreferencedRecordingSnapshotIsComparedByContentNotNameAndSize() async throws {
        let original = Data("take one".utf8)
        let sameSizeOtherAudio = Data("take two".utf8)
        #expect(original.count == sameSizeOtherAudio.count)

        // Another song has a recording with the snapshot's name and size but
        // different audio: the snapshot is still the only copy of its audio.
        let different = try RecoveryHarness()
        try await different.leaveRecoveryCopyAfterRestoreDeletesSong(recording: original, typing: nil)
        try different.writeRecording(sameSizeOtherAudio, named: "100.m4a", projectId: "song-b")
        await different.makeViewModel().waitForRecordingSnapshotSweepForTesting()
        let staged = try different.stagedSnapshots()
        #expect(staged.count == 1)
        #expect(try staged.first.map { try Data(contentsOf: $0.appendingPathComponent("100.m4a")) } == original)

        // Another song has the identical recording: the snapshot is redundant.
        let identical = try RecoveryHarness()
        try await identical.leaveRecoveryCopyAfterRestoreDeletesSong(recording: original, typing: nil)
        try identical.writeRecording(original, named: "100.m4a", projectId: "song-b")
        await identical.makeViewModel().waitForRecordingSnapshotSweepForTesting()
        #expect(try identical.stagedSnapshots().isEmpty)
        #expect(try identical.recordings(for: "song-b") == ["100.m4a": original])
    }

    @Test func snapshotFoundToBeTheOnlyCopyIsNotHashedAgainOnLaterLaunches() async throws {
        let audio = Data("take one".utf8)
        let harness = try RecoveryHarness()
        try await harness.leaveRecoveryCopyAfterRestoreDeletesSong(recording: audio, typing: nil)

        await harness.makeViewModel().waitForRecordingSnapshotSweepForTesting()

        let snapshot = try #require(try harness.stagedSnapshots().first)
        let marker = snapshot.appendingPathComponent(EditorViewModel.recordingSnapshotCheckedMarkerName)
        let checked = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: marker))
        #expect(checked == ["100.m4a": audio.count])

        // An identical live recording appears afterwards. A launch that hashed
        // the snapshot again would now remove it; the marker says it was already
        // checked, so it is left alone.
        try harness.writeRecording(audio, named: "100.m4a", projectId: "song-b")
        await harness.makeViewModel().waitForRecordingSnapshotSweepForTesting()
        #expect(try harness.stagedSnapshots().count == 1)

        // A snapshot whose files changed since the check is checked again.
        try FileManager.default.removeItem(at: marker)
        try JSONEncoder().encode(["100.m4a": audio.count + 1]).write(to: marker)
        await harness.makeViewModel().waitForRecordingSnapshotSweepForTesting()
        #expect(try harness.stagedSnapshots().isEmpty)
    }

    @Test func deletingASongDuringBackupSaysWhenItCanBeDeleted() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        let service = GatedBackupService()
        let viewModel = harness.makeViewModel(service: service)

        let operation = Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()

        #expect(viewModel.projectDeletionNotice == nil)
        #expect(!viewModel.moveProjectToTrash(project))
        #expect(viewModel.projectDeletionNotice == "This song can be moved to Trash once the backup or restore finishes.")
        // The assistant panel reads `errorMessage` as an AI failure with Retry.
        #expect(viewModel.errorMessage == nil)
        #expect(try harness.projects().count == 1)

        service.release()
        await operation.value
        // The song lists show this notice; it goes away when the operation ends.
        #expect(viewModel.projectDeletionNotice == nil)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.moveProjectToTrash(project))
        #expect(try harness.projects().isEmpty)
    }
}

@MainActor
private struct RecoveryHarness {
    let container: ModelContainer
    let recoveryURL: URL
    let memosRoot: URL

    var context: ModelContext { container.mainContext }

    /// True while any copy is waiting: this session's file or one an earlier
    /// session left behind. Files set aside as unreadable do not count.
    var recoveryCopyExists: Bool {
        let files = (try? recoveryFolderFiles()) ?? []
        return files.contains { !$0.lastPathComponent.hasPrefix("unreadable-") }
    }

    func recoveryFolderFiles() throws -> [URL] {
        let folder = recoveryURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }

    /// Types into `project` during a backup that never finishes, leaving the
    /// recovery copy a killed app would leave.
    func leaveRecoveryCopy(for project: SongProject, typing lyrics: String) async throws {
        let service = GatedBackupService()
        let viewModel = makeViewModel(service: service)
        viewModel.loadProject(project)
        Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()
        viewModel.lyrics = lyrics
        viewModel.triggerAutoSave()
        try #require(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    init() throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // On disk: recovery is skipped for in-memory libraries.
        let configuration = ModelConfiguration(
            schema: schema, url: root.appendingPathComponent("library.store"), cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [configuration])
        memosRoot = root.appendingPathComponent("voice-memos", isDirectory: true)
        recoveryURL = root
            .appendingPathComponent("DraftRecovery", isDirectory: true)
            .appendingPathComponent("open-draft.json")
    }

    func seedProject(id: String, title: String, lyrics: String) throws -> SongProject {
        let project = SongProject(id: id, title: title, lyrics: lyrics)
        context.insert(project)
        try context.save()
        return project
    }

    func projects() throws -> [SongProject] {
        try context.fetch(FetchDescriptor<SongProject>())
    }

    func writeRecording(_ data: Data, named name: String, projectId: String) throws {
        let folder = memosRoot.appendingPathComponent(projectId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }

    func recordingFolders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: memosRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: memosRoot, includingPropertiesForKeys: nil)
    }

    func recordings(for projectId: String) throws -> [String: Data] {
        let folder = memosRoot.appendingPathComponent(projectId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
        var result: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            result[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return result
    }

    /// Recording snapshots a session took for an operation and has not discarded.
    func stagedSnapshots() throws -> [URL] {
        let staging = memosRoot.deletingLastPathComponent()
            .appendingPathComponent("recording-recovery", isDirectory: true)
        guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
    }

    /// Opens "song-a" with one recording, starts a restore that deletes the song
    /// and its recordings and then never finishes, and optionally types into it.
    func leaveRecoveryCopyAfterRestoreDeletesSong(recording: Data, typing lyrics: String?) async throws {
        let project = try seedProject(id: "song-a", title: "A", lyrics: "saved A")
        try writeRecording(recording, named: "100.m4a", projectId: "song-a")
        let songFolder = memosRoot.appendingPathComponent("song-a", isDirectory: true)
        let service = GatedBackupService()
        service.onStart = { context in
            context.delete(project)
            try context.save()
            try FileManager.default.removeItem(at: songFolder)
        }
        let viewModel = makeViewModel(service: service)
        viewModel.loadProject(project)
        Task { await viewModel.restoreBackupNow() }
        try await service.waitUntilStarted()
        if let lyrics {
            viewModel.lyrics = lyrics
            viewModel.triggerAutoSave()
            try #require(FileManager.default.fileExists(atPath: recoveryURL.path))
        }
    }

    /// A new view model on the same store and recovery file, as after a launch.
    func makeViewModel(
        service: GatedBackupService? = nil,
        cloudBacked: Bool? = nil,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) -> EditorViewModel {
        let service = service ?? GatedBackupService()
        service.recordingRecoveryRoot = memosRoot
        let viewModel = EditorViewModel(
            keychainStore: InMemoryKeychainStore(),
            backupService: service,
            draftRecoveryURL: recoveryURL,
            libraryIsCloudBacked: cloudBacked.map { value in { _ in value } },
            saveModelContext: save
        )
        viewModel.modelContext = context
        return viewModel
    }
}

/// A backup service whose operations stall until released; never releasing one
/// models the app being killed mid-operation.
@MainActor
private final class GatedBackupService: CloudBackupServicing {
    var isConfigured = true
    var hasStoredPassphrase = true
    var recordingRecoveryRoot: URL?
    var onStart: ((ModelContext) throws -> Void)?
    private(set) var started = false
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation

    init() {
        (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func release() {
        gateContinuation.finish()
    }

    func waitUntilStarted() async throws {
        for _ in 0..<2_000 where !started {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(started)
    }

    func updatePassphrase(_ passphrase: String) throws {}

    func backupNow(modelContext: ModelContext) async throws {
        try await hold(modelContext)
    }

    func restoreNow(modelContext: ModelContext) async throws {
        try await hold(modelContext)
    }

    func backupInBackgroundIfPossible(modelContext: ModelContext) async {
        try? await hold(modelContext)
    }

    private func hold(_ modelContext: ModelContext) async throws {
        try onStart?(modelContext)
        started = true
        for await _ in gate {}
    }
}
