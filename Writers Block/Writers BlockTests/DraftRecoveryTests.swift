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

    @Test func deletingASongDuringBackupSaysWhenItCanBeDeleted() async throws {
        let harness = try RecoveryHarness()
        let project = try harness.seedProject(id: "song-a", title: "A", lyrics: "saved A")
        let service = GatedBackupService()
        let viewModel = harness.makeViewModel(service: service)

        let operation = Task { await viewModel.backUpNow() }
        try await service.waitUntilStarted()

        #expect(!viewModel.moveProjectToTrash(project))
        #expect(viewModel.errorMessage == "This song can be moved to Trash once the backup or restore finishes.")
        #expect(try harness.projects().count == 1)

        service.release()
        await operation.value
        #expect(viewModel.moveProjectToTrash(project))
        #expect(try harness.projects().isEmpty)
    }
}

@MainActor
private struct RecoveryHarness {
    let container: ModelContainer
    let recoveryURL: URL

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

    /// A new view model on the same store and recovery file, as after a launch.
    func makeViewModel(
        service: GatedBackupService? = nil,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) -> EditorViewModel {
        let viewModel = EditorViewModel(
            keychainStore: InMemoryKeychainStore(),
            backupService: service ?? GatedBackupService(),
            draftRecoveryURL: recoveryURL,
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
