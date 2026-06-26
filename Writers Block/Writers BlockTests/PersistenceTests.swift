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
    private static func makeHarness(backupService: CloudBackupServicing? = nil) throws -> Harness {
        let schema = Schema([SongProject.self, TrashedSongProject.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel(backupService: backupService)
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
