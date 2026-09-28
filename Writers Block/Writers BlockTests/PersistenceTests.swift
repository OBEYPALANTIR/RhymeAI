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

        try await Task.sleep(for: .milliseconds(1_300))

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

        harness.viewModel.theme = "after"
        try await Task.sleep(for: .milliseconds(400))
        #expect(project.theme == "before")

        try await Task.sleep(for: .milliseconds(900))
        #expect(project.theme == "after")
        #expect(harness.viewModel.saveStatus == .saved)
    }

    @MainActor
    @Test func pendingAutoSaveCannotCrossIntoImportedProject() async throws {
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

        try await Task.sleep(for: .milliseconds(1_300))

        let projects = try Self.fetchProjects(harness.context)
        let persistedOriginal = try #require(projects.first { $0.id == "song-a" })
        let imported = try #require(projects.first { $0.id == viewModel.currentProjectId })
        #expect(persistedOriginal.lyrics == "persisted original")
        #expect(imported.lyrics == "imported lyric")
        #expect(viewModel.lyrics == "imported lyric")
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
    @Test func cloudBackupManualActionsPersistPassphraseAndUseConfiguredService() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, hasStoredPassphrase: false)
        let harness = try Self.makeHarness(backupService: backupService)
        let viewModel = harness.viewModel

        #expect(viewModel.canRunCloudBackup == false)
        #expect(viewModel.cloudBackupStatusText == "Enter a backup passphrase to enable Google Drive backup.")

        viewModel.updateCloudBackupPassphrase("shared secret")

        #expect(backupService.updatedPassphrases == ["shared secret"])
        #expect(viewModel.canRunCloudBackup == true)

        await viewModel.backUpNow()
        await viewModel.restoreBackupNow()

        #expect(backupService.backupCalls == 1)
        #expect(backupService.restoreCalls == 1)
        #expect(viewModel.cloudBackupStatusText == "Restore complete. Projects, trash, and missing recordings were restored.")
    }


    @MainActor
    @Test func restoreDoesNotStartWhenOpenDraftCannotBeSaved() async throws {
        let backupService = FakeCloudBackupService(isConfigured: true, hasStoredPassphrase: true)
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
    @Test func cloudBackupBackgroundSyncOnlyRunsAfterSetupExists() async throws {
        let unconfigured = FakeCloudBackupService(isConfigured: false, hasStoredPassphrase: true)
        var harness = try Self.makeHarness(backupService: unconfigured)
        await harness.viewModel.runCloudBackupOnBackgroundIfPossible()
        #expect(unconfigured.backgroundCalls == 0)

        let missingPassphrase = FakeCloudBackupService(isConfigured: true, hasStoredPassphrase: false)
        harness = try Self.makeHarness(backupService: missingPassphrase)
        await harness.viewModel.runCloudBackupOnBackgroundIfPossible()
        #expect(missingPassphrase.backgroundCalls == 0)

        let ready = FakeCloudBackupService(isConfigured: true, hasStoredPassphrase: true)
        harness = try Self.makeHarness(backupService: ready)
        await harness.viewModel.runCloudBackupOnBackgroundIfPossible()
        #expect(ready.backgroundCalls == 1)
        #expect(harness.viewModel.cloudBackupStatusText == "Ready to back up projects, trash, and recordings.")
    }

    @MainActor
    private static func makeHarness(
        backupService: CloudBackupServicing? = nil,
        saveModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Harness {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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

    @MainActor
    private final class FakeCloudBackupService: CloudBackupServicing {
        var isConfigured: Bool
        var hasStoredPassphrase: Bool
        private(set) var updatedPassphrases: [String] = []
        private(set) var backupCalls = 0
        private(set) var restoreCalls = 0
        private(set) var backgroundCalls = 0

        init(isConfigured: Bool, hasStoredPassphrase: Bool) {
            self.isConfigured = isConfigured
            self.hasStoredPassphrase = hasStoredPassphrase
        }

        func updatePassphrase(_ passphrase: String) {
            updatedPassphrases.append(passphrase)
            hasStoredPassphrase = !passphrase.isEmpty
        }

        func backupNow(modelContext: ModelContext) async throws {
            backupCalls += 1
        }

        func restoreNow(modelContext: ModelContext) async throws {
            restoreCalls += 1
        }

        func backupInBackgroundIfPossible(modelContext: ModelContext) async {
            backgroundCalls += 1
        }
    }
}
