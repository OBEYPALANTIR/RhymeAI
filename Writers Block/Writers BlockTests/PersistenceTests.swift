import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct PersistenceTests {

    @MainActor
    @Test func importProjectPersistsProjectAndSelectsItForEditing() throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let exported = SongProjectExport(
            from: SongProject(
                id: "source-project-id",
                title: "",
                lyrics: "  imported first line\nimported second line",
                theme: "clear signal",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        viewModel.importProject(exported)

        let projects = try Self.fetchProjects(context)
        let imported = try #require(projects.first)

        #expect(projects.count == 1)
        #expect(imported.id != exported.id)
        #expect(imported.title == "Imported Song")
        #expect(imported.lyrics == exported.lyrics)
        #expect(imported.theme == exported.theme)
        #expect(viewModel.currentProjectId == imported.id)
        #expect(viewModel.title == imported.title)
        #expect(viewModel.lyrics == imported.lyrics)
        #expect(viewModel.theme == imported.theme)
        #expect(viewModel.cursorPosition == imported.lyrics.count)
        #expect(viewModel.saveStatus == .saved)
    }

    @MainActor
    @Test func autoSaveCreatesProjectAndPersistsEditorFields() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context

        viewModel.title = "Autosaved Draft"
        viewModel.lyrics = "first line\nsecond line"
        viewModel.theme = "late-night resolve"
        viewModel.triggerAutoSave()

        await viewModel.waitForPendingAutoSaveForTesting()

        let projects = try Self.fetchProjects(context)
        let saved = try #require(projects.first)

        #expect(projects.count == 1)
        #expect(viewModel.currentProjectId == saved.id)
        #expect(viewModel.saveStatus == .saved)
        #expect(saved.title == "Autosaved Draft")
        #expect(saved.lyrics == "first line\nsecond line")
        #expect(saved.theme == "late-night resolve")
    }

    @MainActor
    @Test func changingOnlyThemeUsesTheOneSecondAutoSave() async throws {
        let harness = try Self.makeHarness()
        let project = SongProject(id: "theme-only", title: "Draft", lyrics: "A line", theme: "before")
        harness.context.insert(project)
        try harness.context.save()
        harness.viewModel.loadProject(project)

        let clock = ContinuousClock()
        let changedAt = clock.now
        harness.viewModel.theme = "after"
        #expect(project.theme == "before")

        await harness.viewModel.waitForPendingAutoSaveForTesting()
        #expect(clock.now - changedAt >= .seconds(1))
        #expect(project.theme == "after")
        #expect(harness.viewModel.saveStatus == .saved)
    }

    @MainActor
    @Test func pendingAutoSaveCompletesAfterItsContainerOwnerIsReleased() async throws {
        let viewModel = EditorViewModel()
        do {
            let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, Recording.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            viewModel.modelContext = container.mainContext
        }
        viewModel.lyrics = "a line that outlives its container's owner"
        viewModel.triggerAutoSave()

        await viewModel.waitForPendingAutoSaveForTesting()

        #expect(viewModel.saveStatus == .saved)
        #expect(viewModel.currentProjectId != nil)
    }

    @MainActor
    @Test func pendingAutoSaveFlushesOriginalBeforeImportWithoutCrossingIntoImportedProject() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let original = SongProject(
            id: "song-a",
            title: "Original",
            lyrics: "persisted original",
            theme: "first"
        )
        harness.context.insert(original)
        try harness.context.save()
        viewModel.loadProject(original)
        viewModel.lyrics = "unsaved editor change"
        viewModel.triggerAutoSave()

        let importedExport = SongProjectExport(
            from: SongProject(
                id: "source",
                title: "Imported",
                lyrics: "imported lyric",
                theme: "second"
            )
        )
        #expect(viewModel.importProject(importedExport))

        await viewModel.waitForPendingAutoSaveForTesting()

        let projects = try Self.fetchProjects(harness.context)
        let persistedOriginal = try #require(projects.first { $0.id == "song-a" })
        let imported = try #require(projects.first { $0.id == viewModel.currentProjectId })
        #expect(persistedOriginal.lyrics == "unsaved editor change")
        #expect(imported.lyrics == "imported lyric")
        #expect(viewModel.lyrics == "imported lyric")
    }

    @MainActor
    @Test func failedSaveShowsRetryStateAndRetrySavesTheSameEdits() throws {
        final class SaveGate { var shouldFail = true }
        let gate = SaveGate()
        let harness = try Self.makeHarness(saveModelContext: { context in
            if gate.shouldFail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let viewModel = harness.viewModel
        // On the welcome screen there is no open draft, so a flush is a no-op.
        viewModel.showWelcome = false
        viewModel.title = "Retry"
        viewModel.lyrics = "line kept in the editor"

        #expect(!viewModel.flushCurrentDraft())
        #expect(viewModel.saveStatus == .failed)
        #expect(viewModel.errorMessage == "Couldn't save this song. Your edits remain open.")
        #expect(viewModel.lyrics == "line kept in the editor")
        #expect(try Self.fetchProjects(harness.context).isEmpty)

        gate.shouldFail = false
        #expect(viewModel.flushCurrentDraft())
        #expect(viewModel.saveStatus == .saved)
        #expect(try Self.fetchProjects(harness.context).map(\.lyrics) == ["line kept in the editor"])
    }

    @MainActor
    @Test func importFailureKeepsEditorAndStoreUnchanged() throws {
        let harness = try Self.makeHarness(saveModelContext: { _ in throw CocoaError(.fileWriteUnknown) })
        let viewModel = harness.viewModel
        let exported = SongProjectExport(
            from: SongProject(id: "source", title: "Import", lyrics: "line", theme: "theme")
        )

        let imported = viewModel.importProject(exported)

        #expect(!imported)
        #expect(try Self.fetchProjects(harness.context).isEmpty)
        #expect(viewModel.currentProjectId == nil)
        #expect(viewModel.saveStatus == .idle)
        #expect(viewModel.errorMessage?.contains("was not imported") == true)
    }


    @MainActor
    @Test func connectingGoogleDriveEnablesManualActions() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: false)
        let harness = try Self.makeHarness(backupService: backupService)
        let viewModel = harness.viewModel

        #expect(viewModel.canRunCloudBackup == false)
        #expect(viewModel.backupStatus == .notConnected)

        await viewModel.connectGoogleDrive()

        #expect(backupService.connectCalls == 1)
        #expect(viewModel.canRunCloudBackup == true)
        #expect(viewModel.firstRunRestoreOffer == nil)

        await viewModel.backUpNow()
        await viewModel.restoreBackupNow()

        #expect(backupService.backupCalls == 1)
        #expect(backupService.restoreCalls == 1)
        #expect(viewModel.cloudBackupStatusText == "Restore complete. Projects, trash, and missing recordings were restored.")
        #expect(viewModel.backupStatus == .connected(lastBackupAt: nil))
    }

    @MainActor
    @Test func disconnectStopsBackupsAndSaysWhenRevokeFailed() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: true)
        backupService.revokeSucceeds = false
        let harness = try Self.makeHarness(backupService: backupService)
        let viewModel = harness.viewModel
        let clock = ManualBackupClock(viewModel)
        viewModel.scheduleAutomaticBackup()
        #expect(viewModel.backupStatus == .pending)

        await viewModel.disconnectGoogleDrive()
        await clock.advance()

        #expect(backupService.disconnectCalls == 1)
        #expect(backupService.backgroundCalls == 0)
        #expect(viewModel.backupStatus == .notConnected)
        #expect(viewModel.canRunCloudBackup == false)
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.cloudBackupStatusText == "Disconnected on this device, but Google still lists the app; remove it at myaccount.google.com/permissions")
    }

    @MainActor
    @Test func savedChangeStartsOneDebouncedBackupAndFailureShowsTheReason() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: true)
        let harness = try Self.makeHarness(backupService: backupService)
        let viewModel = harness.viewModel
        let clock = ManualBackupClock(viewModel)
        viewModel.showWelcome = false

        viewModel.title = "Debounced"
        viewModel.lyrics = "first"
        #expect(viewModel.flushCurrentDraft())
        viewModel.lyrics = "second"
        #expect(viewModel.flushCurrentDraft())
        #expect(viewModel.backupStatus == .pending)
        #expect(backupService.backgroundCalls == 0)

        await clock.advance { backupService.backgroundCalls == 1 }
        #expect(clock.requestedDelays.prefix(2) == [30, 30])
        #expect(backupService.backgroundCalls == 1, "the second save restarted the countdown; one run")
        #expect(viewModel.backupStatus == .connected(lastBackupAt: nil))

        backupService.failure = "offline"
        viewModel.lyrics = "third"
        #expect(viewModel.flushCurrentDraft())
        await clock.advance { clock.requestedDelays.last == 60 }
        #expect(backupService.backgroundCalls == 2)
        // The retry waits out the backoff (a minute after one failure) and the reason stays shown.
        #expect(clock.requestedDelays.last == 60)
        #expect(viewModel.backupStatus == .failed(reason: "offline", lastBackupAt: nil))
    }

    @MainActor
    @Test func firstRunOfferAppearsAfterConnectingAndRestoresOnlyWhenAccepted() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: false)
        backupService.summary = RemoteBackupSummary(songs: 2, recordings: 1)
        let harness = try Self.makeHarness(backupService: backupService)
        let viewModel = harness.viewModel

        await viewModel.connectGoogleDrive()

        #expect(viewModel.firstRunRestoreOffer?.songs == 2)
        #expect(viewModel.firstRunRestoreOffer?.recordings == 1)
        #expect(backupService.restoreCalls == 0)
        await viewModel.runCloudBackupOnBackgroundIfPossible()
        #expect(backupService.backgroundCalls == 0, "no backup merges the remote while the offer is open")

        await viewModel.acceptFirstRunRestore()
        #expect(viewModel.firstRunRestoreOffer == nil)
        #expect(backupService.restoreCalls == 1)

        await viewModel.checkFirstRunRestoreOffer(afterConnecting: true)
        viewModel.declineFirstRunRestore()
        #expect(viewModel.firstRunRestoreOffer == nil)
        #expect(backupService.restoreCalls == 1)
    }

    @MainActor
    @Test func firstRunOfferAtLaunchNeedsAnEmptyLibrary() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: true)
        backupService.summary = RemoteBackupSummary(songs: 1, recordings: 0)
        let empty = try Self.makeHarness(backupService: backupService)
        await empty.viewModel.checkFirstRunRestoreOffer(afterConnecting: false)
        #expect(empty.viewModel.firstRunRestoreOffer?.songs == 1)

        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        container.mainContext.insert(SongProject(title: "Local"))
        try container.mainContext.save()
        let viewModel = EditorViewModel(backupService: backupService)
        viewModel.modelContext = container.mainContext
        await viewModel.checkFirstRunRestoreOffer(afterConnecting: false)
        #expect(viewModel.firstRunRestoreOffer == nil)
    }

    @MainActor
    @Test func recordingChangesAndChangesDuringARunShareTheOneDebounce() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: true)
        let harness = try Self.makeHarness(backupService: backupService)
        let viewModel = harness.viewModel
        let clock = ManualBackupClock(viewModel)
        backupService.duringBackground = { viewModel.voiceMemoService.onFilesChanged?() }

        viewModel.voiceMemoService.onFilesChanged?()
        viewModel.voiceMemoService.onFilesChanged?()
        #expect(viewModel.backupStatus == .pending)

        await clock.advance { backupService.backgroundCalls == 1 }
        #expect(backupService.backgroundCalls == 1, "one run for the two changes")
        #expect(viewModel.backupStatus == .pending, "the change made during the run asked for another")

        await clock.advance { backupService.backgroundCalls == 2 }
        #expect(backupService.backgroundCalls == 2)
        #expect(clock.requestedDelays.count == 3)
    }

    @Test func automaticBackupBackoffDoublesToAnHour() {
        #expect(BackupSchedule.debounce == 30)
        #expect((0...8).map { BackupSchedule.retryDelay(afterFailures: $0) / 60 } == [0, 1, 2, 4, 8, 16, 32, 60, 60])
    }

    @MainActor
    @Test func restoreDoesNotStartWhenOpenDraftCannotBeSaved() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: true)
        let harness = try Self.makeHarness(
            backupService: backupService,
            saveModelContext: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = harness.viewModel
        viewModel.loadProject(project)
        viewModel.lyrics = "unsaved lyric"
        viewModel.triggerAutoSave()

        await viewModel.restoreBackupNow()

        #expect(backupService.restoreCalls == 0)
        #expect(viewModel.currentProjectId == project.id)
        #expect(viewModel.lyrics == "unsaved lyric")
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.cloudBackupStatusText.contains("Restore canceled"))
        #expect(try Self.fetchProjects(harness.context).first?.lyrics == "saved line")
    }

    @MainActor
    @Test func manualBackupDoesNotStartWhenOpenDraftCannotBeSaved() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, isConnected: true)
        let harness = try Self.makeHarness(
            backupService: backupService,
            saveModelContext: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = harness.viewModel
        viewModel.loadProject(project)
        viewModel.lyrics = "unsaved lyric"

        await viewModel.backUpNow()

        #expect(backupService.backupCalls == 0)
        #expect(viewModel.currentProjectId == project.id)
        #expect(viewModel.lyrics == "unsaved lyric")
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.cloudBackupStatusText.contains("Backup canceled"))
        #expect(try Self.fetchProjects(harness.context).first?.lyrics == "saved line")
    }

    @MainActor
    @Test func cloudBackupBackgroundSyncOnlyRunsWhenConnected() async throws {
        let unconfigured = FakeCloudBackupService(isConfigured: false, isConnected: true)
        var harness = try Self.makeHarness(backupService: unconfigured)
        await harness.viewModel.runCloudBackupOnBackgroundIfPossible()
        #expect(unconfigured.backgroundCalls == 0)

        let disconnected = FakeCloudBackupService(isConfigured: true, isConnected: false)
        harness = try Self.makeHarness(backupService: disconnected)
        await harness.viewModel.runCloudBackupOnBackgroundIfPossible()
        #expect(disconnected.backgroundCalls == 0)

        let ready = FakeCloudBackupService(isConfigured: true, isConnected: true)
        harness = try Self.makeHarness(backupService: ready)
        await harness.viewModel.runCloudBackupOnBackgroundIfPossible()
        #expect(ready.backgroundCalls == 1)
        #expect(harness.viewModel.cloudBackupStatusText == "")
        #expect(harness.viewModel.backupStatus == .connected(lastBackupAt: nil))
    }

    @MainActor
    private static func makeHarness(
        backupService: CloudBackupServicing? = nil,
        saveModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Harness {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel(backupService: backupService, saveModelContext: saveModelContext)
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
    private struct Harness {
        let viewModel: EditorViewModel
        let container: ModelContainer

        var context: ModelContext {
            container.mainContext
        }
    }

    /// Stands in for the debounce/backoff timer: delays wait until the test advances.
    @MainActor
    private final class ManualBackupClock {
        private(set) var requestedDelays: [TimeInterval] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(_ viewModel: EditorViewModel) {
            viewModel.automaticBackupSleep = { [weak self] delay in
                guard let self else { return }
                requestedDelays.append(delay)
                await withCheckedContinuation { self.waiting.append($0) }
            }
        }

        /// Lets a just-scheduled delay start waiting, ends every pending delay, then
        /// lets the woken work run until `done` holds. Bounded by yields, not time.
        func advance(until done: () -> Bool = { false }) async {
            for _ in 0..<10_000 where waiting.isEmpty { await Task.yield() }
            let woken = waiting
            waiting = []
            woken.forEach { $0.resume() }
            for _ in 0..<10_000 where !done() { await Task.yield() }
        }
    }

    @MainActor
    private final class FakeCloudBackupService: CloudBackupServicing {
        var isConfigured: Bool
        var isConnected: Bool
        var revokeSucceeds = true
        var summary: RemoteBackupSummary?
        var failure: String?
        private(set) var connectCalls = 0
        private(set) var disconnectCalls = 0
        private(set) var backupCalls = 0
        private(set) var restoreCalls = 0
        private(set) var backgroundCalls = 0

        init(isConfigured: Bool, isConnected: Bool) {
            self.isConfigured = isConfigured
            self.isConnected = isConnected
        }

        var backgroundBackupFailureDescription: String? { failure }

        func connect() async throws {
            connectCalls += 1
            isConnected = true
        }

        func disconnect() async -> Bool {
            disconnectCalls += 1
            isConnected = false
            return revokeSucceeds
        }

        func remoteBackupSummary() async throws -> RemoteBackupSummary? { summary }

        func backupNow(modelContext: ModelContext) async throws {
            backupCalls += 1
        }

        func restoreNow(modelContext: ModelContext) async throws {
            restoreCalls += 1
        }

        var duringBackground: (() -> Void)?

        func backupInBackgroundIfPossible(modelContext: ModelContext) async {
            backgroundCalls += 1
            if backgroundCalls == 1 { duringBackground?() }
        }
    }
}
