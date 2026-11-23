import Foundation
import SwiftData
import Testing
@testable import Writers_Block

@MainActor
struct RestorePendingDraftTests {
    @Test(arguments: [false, true], [false, true])
    func restoreOrImportKeepsOnePendingEditorDraftWithItsRecording(useDrive: Bool, failAfterApply: Bool) async throws {
        let fixture = try await makePendingDraft()
        let manifest = try fixture.remote.encodedManifest()
        let error = BackupError.network("Synthetic failure after apply")
        if useDrive {
            fixture.harness.drive.seed(name: SyncBlob.driveFileName, content: manifest)
            fixture.harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
            if failAfterApply {
                fixture.harness.drive.afterManifestWrite = { throw error }
            }
            await fixture.editor.restoreBackupNow()
        } else {
            let zip = try BackupArchive.zip([
                ("manifest.json", manifest),
                ("recordings/song-a/late.m4a", BackupCoreTests.lateTake.audio)
            ])
            let staging = RecordingFiles.canonicalPath(RecordingFiles.stagingRoot(for: fixture.harness.memosRoot))
            let memos = RecordingFiles.canonicalPath(fixture.harness.memosRoot)
            let hook = RecordingFiles.BoundaryHooks.install { point, source, destination in
                guard failAfterApply, point == .beforeCheck, let destination,
                      RecordingFiles.canonicalPath(source.deletingLastPathComponent()) == staging,
                      RecordingFiles.canonicalPath(destination).hasPrefix(memos + "/") else { return }
                throw error
            }
            defer { RecordingFiles.BoundaryHooks.remove(hook) }
            await fixture.editor.importBackupFile(zip)
        }

        #expect(fixture.editor.cloudBackupLastResultIsError == failAfterApply, "\(fixture.editor.cloudBackupStatusText)")
        if failAfterApply {
            #expect(fixture.editor.cloudBackupStatusText.contains("Synthetic failure after apply"))
            #expect(fixture.editor.cloudBackupStatusText.contains("Displaced lyrics were kept locally."))
        }
        #expect(fixture.editor.lyrics == "pending local words")
        let keptID = try await checkLibrary(fixture)
        #expect(fixture.editor.currentProjectId == keptID)
    }

    @Test(arguments: [false, true])
    func restoreKeepsOnePendingEditorDraftWhenSwitchingSongs(afterApply: Bool) async throws {
        let fixture = try await makePendingDraft()
        let destination = SongProject(id: "next-song", title: "Next", lyrics: "other words")
        fixture.harness.context.insert(destination)
        try fixture.harness.context.save()
        fixture.harness.drive.seed(name: SyncBlob.driveFileName, content: try fixture.remote.encodedManifest())
        fixture.harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
        if afterApply {
            fixture.harness.drive.afterManifestWrite = { fixture.editor.loadProject(destination) }
        } else {
            fixture.harness.drive.beforeManifestWrite = { fixture.editor.loadProject(destination) }
        }

        await fixture.editor.restoreBackupNow()

        #expect(!fixture.editor.cloudBackupLastResultIsError, "\(fixture.editor.cloudBackupStatusText)")
        #expect(fixture.editor.currentProjectId == destination.id)
        #expect(fixture.editor.lyrics == "other words")
        _ = try await checkLibrary(fixture)
    }

    @Test func anEditAfterRestoreCommitsKeepsItsOwnSongAndItsRecording() async throws {
        let fixture = try await makePendingDraft()
        fixture.harness.drive.seed(name: SyncBlob.driveFileName, content: try fixture.remote.encodedManifest())
        fixture.harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
        fixture.harness.drive.afterManifestWrite = {
            fixture.editor.lyrics = "later local words"
            fixture.editor.triggerAutoSave()
        }
        await fixture.editor.restoreBackupNow()

        #expect(!fixture.editor.cloudBackupLastResultIsError)
        #expect(await fixture.editor.reconcileRecordings())
        let reopened = try await fixture.harness.reopened()
        let projects = try reopened.context.fetch(FetchDescriptor<SongProject>())
        #expect(projects.first { $0.id == "song-a" }?.lyrics == "remote words")
        let pendingCopies = projects.filter { $0.lyrics == "pending local words" }
        let laterCopies = projects.filter { $0.lyrics == "later local words" }
        #expect(pendingCopies.count == 1 && laterCopies.count == 1)
        let pending = try #require(pendingCopies.first)
        let later = try #require(laterCopies.first)
        #expect(pending.id != later.id)
        #expect(fixture.editor.currentProjectId == later.id)
        #expect(reopened.audios(later.id) == [fixture.audio])
    }

    @Test func aCollidingDraftReservationIsUpdatedInTheJournalBeforeRestoreCommits() async throws {
        let fixture = try await makePendingDraft()
        let draftFile = fixture.harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
        func recordedID() throws -> String {
            let journal = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: draftFile)) as? [String: Any])
            return try #require(journal["separateCopyId"] as? String)
        }
        var originalReservation: String?
        fixture.harness.drive.seed(name: SyncBlob.driveFileName, content: try fixture.remote.encodedManifest())
        fixture.harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
        fixture.harness.drive.beforeManifestWrite = {
            let id = try recordedID()
            originalReservation = id
            fixture.harness.context.insert(SongProject(id: id, title: "Unrelated", lyrics: "other words"))
            try fixture.harness.context.save()
        }
        fixture.harness.drive.afterManifestWrite = {
            let copyID = try recordedID()
            #expect(copyID != originalReservation)
            let copies = try fixture.harness.context.fetch(FetchDescriptor<SongProject>()).filter { $0.lyrics == "pending local words" }
            #expect(copies.map(\.id) == [copyID])
        }

        await fixture.editor.restoreBackupNow()

        #expect(!fixture.editor.cloudBackupLastResultIsError, "\(fixture.editor.cloudBackupStatusText)")
        let kept = try await checkLibrary(fixture)
        #expect(fixture.editor.currentProjectId == kept)
        #expect(try fixture.harness.context.fetch(FetchDescriptor<SongProject>()).contains {
            $0.id == originalReservation && $0.lyrics == "other words"
        })
    }

    @Test(arguments: ["attach", "missingTake", "partial", "alreadyAttached"])
    func relaunchChecksBothTakesBeforeClearingTheCommittedDraftJournal(_ mode: String) async throws {
        let harness = try await BackupCoreTests().makeHarness()
        let original = SongProject(id: "original", title: "Remote", lyrics: "remote words")
        let kept = SongProject(id: "reserved", title: "Recovered", lyrics: "pending words")
        harness.context.insert(original)
        harness.context.insert(kept)
        try harness.context.save()
        let audios = [Data([0x31]), Data([0x32, 0x33])]
        for (index, audio) in audios.enumerated() {
            try await harness.writeMemo(audio, projectId: original.id, fileName: "take-\(index).m4a")
        }
        let snapshot = try #require(try OpenRecordingSnapshot(projectId: original.id, recordingsRoot: harness.memosRoot))
        let takes = try snapshot.takesForRecovery()
        let folder = OpenRecordingSnapshot.stagingRoot(for: harness.memosRoot).appendingPathComponent(snapshot.folderName)
        let recovery = harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
        let journal: [String: Any] = [
            "projectId": original.id, "title": kept.title, "lyrics": kept.lyrics, "theme": kept.theme,
            "baselineTitle": kept.title, "baselineLyrics": kept.lyrics, "baselineTheme": kept.theme,
            "savedAt": Date().timeIntervalSinceReferenceDate, "separateCopyId": kept.id,
            "recordingSnapshotFolder": snapshot.folderName,
            "recordingTakes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(takes))
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)
        if mode == "missingTake" {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(try #require(takes.first).fileName))
        } else if mode == "partial" {
            let take = try #require(takes.first)
            let target = harness.file(take.recordingID(for: kept.id), kept.id)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = folder.appendingPathComponent(take.fileName)
            try FileManager.default.moveItem(at: source, to: target)
        } else if mode == "alreadyAttached" {
            try snapshot.copy(to: kept.id, verifyDestination: true)
            try FileManager.default.removeItem(at: folder)
        }

        let reopened = try await harness.reopened()
        let editor = EditorViewModel(
            keychainStore: InMemoryKeychainStore(), backupService: reopened.service,
            recordingLibrary: reopened.service.library, defaults: reopened.defaults, draftRecoveryURL: recovery
        )
        editor.modelContext = reopened.context
        await editor.recordingsLaunchTask?.value

        let projects = try reopened.context.fetch(FetchDescriptor<SongProject>())
        #expect(projects.filter { $0.lyrics == "pending words" }.map(\.id) == ["reserved"])
        let files = try FileManager.default.contentsOfDirectory(atPath: recovery.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("unrecovered-") } == (mode == "missingTake"))
        #expect(reopened.audios("reserved") == (mode == "missingTake" ? [] : Set(audios)))
        if mode == "missingTake" {
            #expect(editor.errorMessage?.contains("retried") == true)
        } else {
            let recordings = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == "reserved" }
            #expect(recordings.count == 2)
        }
    }

    private typealias PendingFixture = (harness: BackupHarness, editor: EditorViewModel, remote: SyncBlob, audio: Data)

    private func makePendingDraft() async throws -> PendingFixture {
        let harness = try await BackupCoreTests().makeHarness()
        let original = SongProject(id: "song-a", title: "Local A", lyrics: "saved local words", theme: "calm")
        let audio = Data([0x31, 0x32, 0x33, 0x34])
        harness.context.insert(original)
        try harness.context.save()
        try await harness.writeMemo(audio, projectId: original.id, fileName: "local-take.m4a")
        let editor = EditorViewModel(
            keychainStore: InMemoryKeychainStore(), backupService: harness.service,
            recordingLibrary: harness.service.library, defaults: harness.defaults,
            draftRecoveryURL: harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
        )
        editor.modelContext = harness.context
        await editor.recordingsLaunchTask?.value
        editor.loadProject(original)
        editor.lyrics = "pending local words"
        editor.triggerAutoSave()
        let remote = SyncBlob(
            projects: [SyncSongProject(id: original.id, title: "Remote A", lyrics: "remote words",
                                      theme: "loud", updatedAt: Date().addingTimeInterval(3_600))],
            recordings: [BackupCoreTests.lateTake.entry]
        )
        return (harness, editor, remote, audio)
    }

    private func checkLibrary(_ fixture: PendingFixture) async throws -> String {
        #expect(await fixture.editor.reconcileRecordings())
        let reopened = try await fixture.harness.reopened()
        let projects = try reopened.context.fetch(FetchDescriptor<SongProject>())
        #expect(projects.first { $0.id == "song-a" }?.lyrics == "remote words")
        let copies = projects.filter { $0.lyrics == "pending local words" }
        #expect(copies.map(\.title) == ["Local A"])
        let kept = try #require(copies.first { $0.title == "Local A" })
        #expect(kept.id != "song-a")
        #expect(kept.theme == "calm")
        #expect(reopened.audios(kept.id) == [fixture.audio])
        let takes = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == kept.id }
        #expect(takes.map(\.displayName) == ["local-take.m4a"])
        return kept.id
    }
}
