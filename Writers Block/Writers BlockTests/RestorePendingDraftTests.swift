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

    @Test func failedParkWhileSwitchingSpendsTheSavedDraftID() async throws {
        let firstWords = "first outgoing draft under the restore hold"
        let secondWords = "second outgoing draft under the restore hold"
        var recovery: URL?
        var frozen: Data?
        let fixture = try await makePendingDraft(save: { context in
            try context.save()
            guard let recovery, frozen == nil,
                  try context.fetch(FetchDescriptor<SongProject>()).contains(where: { $0.lyrics == firstWords }) else { return }
            frozen = try Data(contentsOf: recovery)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: recovery.path)
        })
        let harness = fixture.harness
        let journal = recoveryURL(harness)
        recovery = journal
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path) }
        let next = SongProject(id: "next-song", title: "Next", lyrics: "next saved words")
        let last = SongProject(id: "last-song", title: "Last", lyrics: "last saved words")
        harness.context.insert(next)
        harness.context.insert(last)
        try harness.context.save()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try fixture.remote.encodedManifest())
        harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
        harness.drive.beforeManifestWrite = {
            fixture.editor.lyrics = firstWords
            fixture.editor.triggerAutoSave()
            fixture.editor.loadProject(next)
            let preSeal = try #require(frozen)
            #expect(try Data(contentsOf: journal) == preSeal)
            let first = try #require(try harness.context.fetch(FetchDescriptor<SongProject>()).first { $0.lyrics == firstWords })
            #expect(fixture.editor.currentProjectId == first.id)

            fixture.editor.loadProject(next)
            #expect(fixture.editor.currentProjectId == next.id)
            fixture.editor.lyrics = secondWords
            fixture.editor.triggerAutoSave()
            fixture.editor.loadProject(last)
            #expect(fixture.editor.currentProjectId == last.id)
            let songs = try harness.context.fetch(FetchDescriptor<SongProject>())
            let second = try #require(songs.first { $0.lyrics == secondWords })
            #expect(first.id != second.id)
            #expect(Set(songs.map(\.id)).count == songs.count)
            #expect(songs.first { $0.id == next.id }?.lyrics == "next saved words")
            #expect(try Data(contentsOf: journal) == preSeal)
        }

        await fixture.editor.restoreBackupNow()

        #expect(!fixture.editor.cloudBackupLastResultIsError, "\(fixture.editor.cloudBackupStatusText)")
        let reopened = try await harness.reopened()
        let recovered = try reopened.context.fetch(FetchDescriptor<SongProject>()).filter { [firstWords, secondWords].contains($0.lyrics) }
        #expect(Set(recovered.map(\.id)).count == 2)
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

    @Test func restoringASongDeletionKeepsTheTakeOnTheSeparateDraft() async throws {
        let fixture = try await makePendingDraft()
        let harness = fixture.harness
        let originalTake = try #require(try harness.context.fetch(FetchDescriptor<Recording>()).first)
        let originalTakeID = originalTake.id
        let deletion = SyncDeletion(projectId: "song-a", deletedAt: Date().addingTimeInterval(3_600).epochMilliseconds)
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(deletions: [deletion]).encodedManifest())
        harness.drive.beforeManifestWrite = {
            fixture.editor.lyrics = "typed while the remote deletion waited"
            fixture.editor.triggerAutoSave()
        }

        await fixture.editor.restoreBackupNow()

        let reopened = try await harness.reopened()
        let songs = try reopened.context.fetch(FetchDescriptor<SongProject>())
        #expect(!songs.contains { $0.id == "song-a" })
        let recovered = try #require(songs.first { $0.lyrics == "typed while the remote deletion waited" })
        let storedDeletions = try DeletionStore.all(in: reopened.context)
        #expect(storedDeletions.contains { $0.projectId == "song-a" && $0.recordingId == originalTakeID && $0.deletedAt == deletion.deletedAt })
        let playable = try reopened.service.library.liveRecordings(projectId: recovered.id, in: reopened.context)
        #expect(try playable.map { try Data(contentsOf: $0.url) } == [fixture.audio])
        #expect(try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == recovered.id }.map(\.audio) == [fixture.audio])
    }

    @Test(arguments: [false, true], [false, true])
    func pendingTakeRemembersTheCascadeAfterTheSourceDeletionAdvances(manifestCascade: Bool, explicitTakeDeletion: Bool) async throws {
        let words = "editor words kept apart from the deleted song"
        var recovery: URL?
        var frozen: Data?
        let fixture = try await makePendingDraft(save: { context in
            try context.save()
            guard let recovery, frozen == nil,
                  try context.fetch(FetchDescriptor<SongProject>()).contains(where: { $0.lyrics == words }) else { return }
            frozen = try Data(contentsOf: recovery)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: recovery.path)
        })
        let harness = fixture.harness
        let journal = recoveryURL(harness)
        recovery = journal
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path) }
        let entry = try #require(try harness.context.fetch(FetchDescriptor<Recording>()).first?.syncEntry)
        let takeID = entry.id
        let t1 = Date().addingTimeInterval(3_600).epochMilliseconds
        let t2 = t1 + 2
        let t3 = t2 + 2
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try SyncBlob(deletions: [SyncDeletion(projectId: "song-a", deletedAt: t1)]).encodedManifest())
        harness.drive.beforeManifestWrite = {
            fixture.editor.lyrics = words
            fixture.editor.triggerAutoSave()
        }

        await fixture.editor.restoreBackupNow()

        let preSeal = try #require(frozen)
        #expect(try Data(contentsOf: journal) == preSeal)
        let between = try await harness.reopened()
        let draft = try #require(try between.context.fetch(FetchDescriptor<SongProject>()).first { $0.lyrics == words })
        let draftID = draft.id
        let owner = try durableRowID(draft)
        #expect(between.audios(draftID).isEmpty)
        let rows = try between.context.fetch(FetchDescriptor<Recording>())
        #expect(!rows.contains { $0.id == takeID || $0.projectId == draftID })
        let firstDeletions = try DeletionStore.all(in: between.context).filter { $0.projectId == "song-a" }
        #expect(firstDeletions.contains { $0.isSongTombstone && $0.deletedAt == t1 })
        #expect(firstDeletions.contains { $0.recordingId == takeID && $0.deletedAt == t1 })

        harness.drive.beforeManifestWrite = nil
        var remote = [SyncDeletion(projectId: "song-a", deletedAt: t2)]
        if explicitTakeDeletion { remote.append(SyncDeletion(projectId: "song-a", recordingId: takeID, deletedAt: t2 + 1)) }
        let imported = SyncBlob(recordings: manifestCascade ? [entry] : [], deletions: remote)
        try await between.service.importArchive(try imported.encodedManifest(), modelContext: between.context)
        let takeTime = explicitTakeDeletion ? t2 + 1 : (manifestCascade ? t2 : t1)
        let afterImport = try DeletionStore.all(in: between.context).filter { $0.projectId == "song-a" }
        #expect(afterImport.filter(\.isSongTombstone).map(\.deletedAt) == [t2])
        #expect(afterImport.filter { $0.recordingId == takeID }.map(\.deletedAt) == [takeTime])

        let newest = SyncBlob(deletions: [SyncDeletion(projectId: "song-a", deletedAt: t3)])
        harness.drive.seed(name: SyncBlob.driveFileName, content: try newest.encodedManifest())
        try await between.service.restoreNow(modelContext: between.context)
        let advanced = try DeletionStore.all(in: between.context).filter { $0.projectId == "song-a" }
        #expect(advanced.filter(\.isSongTombstone).map(\.deletedAt) == [t3])
        #expect(advanced.filter { $0.recordingId == takeID }.map(\.deletedAt) == [takeTime])
        #expect(try Data(contentsOf: journal) == preSeal)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path)

        let reopened = try await reopenEditor(between, recovery: journal)

        let songs = try reopened.context.fetch(FetchDescriptor<SongProject>())
        #expect(!songs.contains { $0.id == "song-a" })
        #expect(try songs.first { $0.id == draftID }.map(durableRowID) == owner)
        let playable = try reopened.service.library.liveRecordings(projectId: draftID, in: reopened.context)
        let expected = explicitTakeDeletion ? [] : [fixture.audio]
        let playableBytes = try playable.map { try Data(contentsOf: $0.url) }
        let storedBytes = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == draftID }.map(\.audio)
        #expect(playableBytes == expected)
        #expect(storedBytes == expected)
    }

    @Test(arguments: [false, true])
    func publishedRecoveryDistinguishesACascadeFromATakeDeletion(cascade: Bool) async throws {
        let (harness, recovery, snapshot, take, bytes) = try await singleTakeRecovery()
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent(take.fileName))
        let first = try await reopenEditor(harness, recovery: recovery)
        try seedPublishedRecovery(take, bytes: bytes, projectId: "reserved", harness: first, recovery: recovery)
        let sourceRecordingId = URL(fileURLWithPath: take.fileName).deletingPathExtension().lastPathComponent
        let deletedAt = Date().addingTimeInterval(120).epochMilliseconds
        if cascade {
            let original = try #require(try first.context.fetch(FetchDescriptor<SongProject>()).first { $0.id == "original" })
            first.context.delete(original)
            try DeletionStore.upsert(SyncDeletion(projectId: "original", deletedAt: deletedAt), in: first.context)
        }
        try DeletionStore.upsert(SyncDeletion(projectId: "original", recordingId: sourceRecordingId, deletedAt: deletedAt),
                                in: first.context)
        try first.context.save()

        let reopened = try await reopenEditor(first, recovery: recovery)

        let rows = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == "reserved" }
        #expect(rows.map(\.audio) == (cascade ? [bytes] : []))
        #expect(reopened.audios("reserved") == (cascade ? [bytes] : []))
        #expect(try retryJournals(beside: recovery).isEmpty)
    }

    @Test func aFailedReceiptWriteKeepsTheCommittedEditorDraftOwned() async throws {
        var recovery: URL?
        var frozen: Data?
        let words = "editor words after the service saved its copy"
        let fixture = try await makePendingDraft(save: { context in
            try context.save()
            guard let recovery, frozen == nil,
                  try context.fetch(FetchDescriptor<SongProject>()).contains(where: { $0.lyrics == words }) else { return }
            frozen = try Data(contentsOf: recovery)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: recovery.path)
        })
        let harness = fixture.harness
        let journal = recoveryURL(harness)
        recovery = journal
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path) }
        harness.drive.seed(name: SyncBlob.driveFileName, content: try fixture.remote.encodedManifest())
        harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
        harness.drive.afterManifestWrite = {
            fixture.editor.lyrics = words
            fixture.editor.triggerAutoSave()
        }

        await fixture.editor.restoreBackupNow()

        let preSeal = try #require(frozen)
        #expect(try Data(contentsOf: journal) == preSeal)
        #expect(fixture.editor.cloudBackupLastResultIsError)
        let stored = try #require(try harness.context.fetch(FetchDescriptor<SongProject>()).first { $0.lyrics == words })
        let owner = try durableRowID(stored)
        #expect(fixture.editor.currentProjectId == stored.id)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path)
        fixture.editor.lyrics = "new words after the failed receipt"
        #expect(fixture.editor.flushCurrentDraft())

        let reopened = try await harness.reopened()
        let songs = try reopened.context.fetch(FetchDescriptor<SongProject>())
        let updated = try #require(songs.first { $0.lyrics == "new words after the failed receipt" })
        #expect(try durableRowID(updated) == owner)
        #expect(songs.count == 3)
        #expect(!songs.contains { $0.lyrics == words })
        #expect(try Data(contentsOf: journal) == preSeal)
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

    @Test(arguments: ["attach", "missingTake", "partial", "alreadyAttached", "alternateAttached", "ambiguous"])
    func relaunchChecksBothTakesBeforeClearingTheCommittedDraftJournal(_ mode: String) async throws {
        let harness = try await BackupCoreTests().makeHarness()
        let original = SongProject(id: "original", title: "Remote", lyrics: "remote words")
        let kept = SongProject(id: "reserved", title: "Recovered", lyrics: "pending words")
        harness.context.insert(original)
        harness.context.insert(kept)
        if mode == "ambiguous" {
            harness.context.insert(TrashedSongProject(id: kept.id, title: "Unrelated", lyrics: "other words",
                                                       theme: "", updatedAt: Date()))
        }
        try harness.context.save()
        let audios = [Data([0x31]), Data([0x32, 0x33])]
        for (index, audio) in audios.enumerated() {
            try await harness.writeMemo(audio, projectId: original.id, fileName: "take-\(index).m4a")
        }
        let snapshot = try #require(try OpenRecordingSnapshot(projectId: original.id, recordingsRoot: harness.memosRoot))
        let takes = try snapshot.takesForRecovery()
        let folder = OpenRecordingSnapshot.stagingRoot(for: harness.memosRoot).appendingPathComponent(snapshot.folderName)
        let recovery = harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
        var journal: [String: Any] = [
            "projectId": original.id, "title": kept.title, "lyrics": kept.lyrics, "theme": kept.theme,
            "baselineTitle": kept.title, "baselineLyrics": kept.lyrics, "baselineTheme": kept.theme,
            "savedAt": Date().timeIntervalSinceReferenceDate, "separateCopyId": kept.id,
            "recordingSnapshotFolder": snapshot.folderName,
            "recordingTakes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(takes))
        ]
        var expectedAudio = Set(audios)
        var alternateID: String?
        if mode == "missingTake" {
            let missing = folder.appendingPathComponent(try #require(takes.first).fileName)
            expectedAudio.remove(try Data(contentsOf: missing))
            try FileManager.default.removeItem(at: missing)
        } else if mode == "partial" {
            let take = try #require(takes.first)
            let target = harness.file(take.recordingID(for: kept.id), kept.id)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = folder.appendingPathComponent(take.fileName)
            try FileManager.default.moveItem(at: source, to: target)
        } else if mode == "alreadyAttached" || mode == "alternateAttached" {
            try snapshot.copy(to: kept.id, verifyDestination: true)
            if mode == "alternateAttached" {
                let take = try #require(takes.first)
                let originalID = take.recordingID(for: kept.id)
                let id = UUID().uuidString.lowercased()
                alternateID = id
                // Simulate an interruption after the mapped take and the other take both reached disk.
                try FileManager.default.moveItem(at: harness.file(originalID, kept.id), to: harness.file(id, kept.id))
                let occupant = Data([0x62])
                try harness.writeFile(occupant, projectId: kept.id, fileName: "\(originalID).m4a")
                expectedAudio.insert(occupant)
                journal["recordingIDs"] = [originalID: id]
            }
            try FileManager.default.removeItem(at: folder)
        }
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)

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
        let retry = mode == "missingTake" || mode == "ambiguous"
        #expect(files.contains { $0.hasPrefix("unrecovered-") } == retry)
        #expect(reopened.audios("reserved") == (mode == "ambiguous" ? [] : expectedAudio))
        if retry {
            #expect(editor.errorMessage?.contains("retried") == true)
        } else {
            let recordings = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == "reserved" }
            #expect(recordings.count == expectedAudio.count)
            if let alternateID { #expect(recordings.contains { $0.id == alternateID }) }
        }
    }

    @Test func restoreKeepsBothTakesWhenTheRecoveryRecordingPathIsOccupied() async throws {
        let fixture = try await makePendingDraft()
        let otherAudio = Data([0x51, 0x52])
        let recovery = fixture.harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
        var occupiedID: String?
        fixture.harness.drive.seed(name: SyncBlob.driveFileName, content: try fixture.remote.encodedManifest())
        fixture.harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
        fixture.harness.drive.afterManifestWrite = {
            let journal = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: recovery)) as? [String: Any])
            let copyID = try #require(journal["separateCopyId"] as? String)
            let data = try JSONSerialization.data(withJSONObject: try #require(journal["recordingTakes"]))
            let take = try #require(try JSONDecoder().decode([OpenRecordingSnapshot.Take].self, from: data).first)
            let id = take.recordingID(for: copyID)
            occupiedID = id
            try fixture.harness.writeFile(otherAudio, projectId: copyID, fileName: "\(id).m4a")
            fixture.harness.context.insert(Recording(id: id, projectId: copyID, displayName: "Other take.m4a",
                                                     audio: otherAudio, recordedAt: Date()))
            try fixture.harness.context.save()
        }

        await fixture.editor.restoreBackupNow()

        let keptID = try #require(fixture.editor.currentProjectId)
        #expect(await fixture.editor.reconcileRecordings())
        let first = try await reopenEditor(fixture.harness, recovery: recovery)
        let firstIDs = try first.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == keptID }.map(\.id).sorted()
        let reopened = try await reopenEditor(first, recovery: recovery)
        let projects = try reopened.context.fetch(FetchDescriptor<SongProject>())
        #expect(projects.filter { $0.lyrics == "pending local words" }.map(\.id) == [keptID])
        #expect(reopened.audios(keptID) == [fixture.audio, otherAudio])
        let takes = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == keptID }
        #expect(takes.map(\.id).sorted() == firstIDs)
        #expect(takes.count == 2)
        #expect(takes.first { $0.id == occupiedID }?.audio == otherAudio)
        #expect(try retryJournals(beside: recovery).isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func audioRetryAfterAnOrdinaryEditKeepsTheLatestWordsOnTheSameSong(inPlace: Bool, missingFolder: Bool) async throws {
        let harness = try await BackupCoreTests().makeHarness()
        let original = SongProject(id: "original", title: "Original", lyrics: "baseline")
        harness.context.insert(original)
        try harness.context.save()
        let audio = [Data([0x41]), Data([0x42, 0x43])]
        for (index, bytes) in audio.enumerated() {
            try await harness.writeMemo(bytes, projectId: original.id, fileName: "take-\(index).m4a")
        }
        let snapshot = try #require(try OpenRecordingSnapshot(projectId: original.id, recordingsRoot: harness.memosRoot))
        let takes = try snapshot.takesForRecovery()
        let folder = OpenRecordingSnapshot.stagingRoot(for: harness.memosRoot).appendingPathComponent(snapshot.folderName)
        let firstTake = try #require(takes.first)
        let lost = try Data(contentsOf: folder.appendingPathComponent(firstTake.fileName))
        // The original takes no longer exist at their live paths.
        for recording in try harness.context.fetch(FetchDescriptor<Recording>()) { harness.context.delete(recording) }
        try harness.context.save()
        try FileManager.default.removeItem(at: harness.memosRoot.appendingPathComponent(original.id))
        if !inPlace {
            original.lyrics = "remote winner"
            try harness.context.save()
        }
        let recovery = harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
        let journal: [String: Any] = [
            "projectId": original.id, "title": original.title, "lyrics": "last typed words", "theme": "",
            "baselineTitle": original.title, "baselineLyrics": "baseline", "baselineTheme": "",
            "savedAt": Date().timeIntervalSinceReferenceDate, "separateCopyId": "reserved",
            "recordingSnapshotFolder": snapshot.folderName,
            "recordingTakes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(takes))
        ]
        if missingFolder {
            try FileManager.default.removeItem(at: folder)
        } else {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(firstTake.fileName))
        }
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)

        let (first, editor) = try await reopenRecoveryEditor(harness, recovery: recovery)
        let keptID = inPlace ? original.id : "reserved"
        let saved = try first.context.fetch(FetchDescriptor<SongProject>())
        #expect(saved.filter { $0.lyrics == "last typed words" }.map(\.id) == [keptID])
        #expect(try retryJournals(beside: recovery).count == 1)
        let kept = try #require(saved.first { $0.id == keptID && $0.lyrics == "last typed words" })
        let owner = try durableRowID(kept)
        if !missingFolder {
            let remaining = try #require(takes.last)
            let remainingBytes = try Data(contentsOf: folder.appendingPathComponent(remaining.fileName))
            #expect(first.audios(keptID) == [remainingBytes])
            let adopted = try first.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == keptID }
            #expect(adopted.map(\.audio) == [remainingBytes])
            let retryName = try #require(try retryJournals(beside: recovery).first)
            let retryFile = recovery.deletingLastPathComponent().appendingPathComponent(retryName)
            let retry = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: retryFile)) as? [String: Any])
            let inventory = try #require(retry["recordingTakes"] as? [[String: Any]])
            #expect(inventory.contains { $0["fileName"] as? String == firstTake.fileName })
            editor.loadProject(kept)
            editor.lyrics = "words edited after recovery"
            #expect(editor.flushCurrentDraft())
            try lost.write(to: folder.appendingPathComponent(firstTake.fileName))
            let second = try await reopenEditor(first, recovery: recovery)
            let songs = try second.context.fetch(FetchDescriptor<SongProject>())
            #expect(songs.allSatisfy { $0.lyrics != "last typed words" })
            #expect(try songs.first { $0.id == keptID }.map(durableRowID) == owner)
            #expect(songs.first { $0.id == keptID }?.lyrics == "words edited after recovery")
            #expect(second.audios(keptID) == Set(audio))
            #expect(try retryJournals(beside: recovery).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func relaunchRecoversIntactTakesWithoutAReadableNameIndex(corrupt: Bool) async throws {
        let harness = try await BackupCoreTests().makeHarness()
        let song = SongProject(id: "original", title: "Original", lyrics: "remote winner")
        harness.context.insert(song)
        try harness.context.save()
        let bytes = Data([0x41, 0x42])
        try await harness.writeMemo(bytes, projectId: song.id, fileName: "physical.m4a")
        let row = try #require(try harness.context.fetch(FetchDescriptor<Recording>()).first)
        let snapshot = try #require(try OpenRecordingSnapshot(projectId: song.id, recordingsRoot: harness.memosRoot,
                                                              displayNames: [row.storedName: "Named take.m4a"]))
        let takes = try snapshot.takesForRecovery()
        let folder = OpenRecordingSnapshot.stagingRoot(for: harness.memosRoot).appendingPathComponent(snapshot.folderName)
        let recovery = harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
        let journal: [String: Any] = [
            "projectId": song.id, "title": "Local", "lyrics": "local words", "theme": "",
            "baselineTitle": song.title, "baselineLyrics": "baseline", "baselineTheme": "",
            "savedAt": Date().timeIntervalSinceReferenceDate, "separateCopyId": "reserved",
            "recordingSnapshotFolder": snapshot.folderName,
            "recordingTakes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(takes))
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)
        let names = folder.appendingPathComponent("names.json")
        if corrupt { try Data([0x00]).write(to: names) } else { try FileManager.default.removeItem(at: names) }
        let reopened = try await reopenEditor(harness, recovery: recovery)
        let attached = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == "reserved" }
        #expect(attached.map(\.audio) == [bytes])
        #expect(attached.map(\.displayName) == ["Named take.m4a"])
        #expect(try retryJournals(beside: recovery).isEmpty)
    }

    @Test func returningToTheDisplacedDraftKeepsItsOriginalTitle() async throws {
        let fixture = try await makePendingDraft()
        fixture.harness.drive.seed(name: SyncBlob.driveFileName, content: try fixture.remote.encodedManifest())
        fixture.harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
        fixture.harness.drive.beforeManifestWrite = {
            fixture.editor.lyrics = "intervening words"
            fixture.editor.triggerAutoSave()
        }
        fixture.harness.drive.afterManifestWrite = {
            let copies = try fixture.harness.context.fetch(FetchDescriptor<SongProject>()).filter { $0.lyrics == "pending local words" }
            #expect(copies.map(\.title) == ["Local A (before restore)"])
            fixture.editor.lyrics = "pending local words"
            fixture.editor.triggerAutoSave()
        }

        await fixture.editor.restoreBackupNow()

        #expect(fixture.editor.title == "Local A")
        let keptID = try await checkLibrary(fixture)
        #expect(fixture.editor.currentProjectId == keptID)
    }

    @Test(arguments: ["editor", "editorInPlace", "restore", "import", "beforeIntent", "rollback"])
    func reopenAtTheTextCommitBoundaryResolvesTheAttempt(_ cut: String) async throws {
        if cut == "restore" || cut == "import" {
            let fixture = try await makePendingDraft()
            let harness = fixture.harness
            let recovery = recoveryURL(harness)
            var frozen: (journal: Data, folder: URL, name: String, audio: Data)?
            harness.service.saveAppliedChanges = { context in
                let journal = try Data(contentsOf: recovery)
                let payload = try journalObject(journal)
                let name = try #require(payload["recordingSnapshotFolder"] as? String)
                let folder = OpenRecordingSnapshot.stagingRoot(for: harness.memosRoot).appendingPathComponent(name)
                let inventory = try #require(payload["recordingTakes"] as? [[String: Any]])
                let take = try #require(inventory.first?["fileName"] as? String)
                let audio = try Data(contentsOf: folder.appendingPathComponent(take))
                try context.save()
                frozen = (journal, folder, take, audio)
                try FileManager.default.removeItem(at: folder.appendingPathComponent(take))
            }
            let manifest = try fixture.remote.encodedManifest()
            if cut == "restore" {
                harness.drive.seed(name: SyncBlob.driveFileName, content: manifest)
                harness.drive.seed(name: BackupCoreTests.lateTake.entry.driveName, content: BackupCoreTests.lateTake.audio)
                await fixture.editor.restoreBackupNow()
            } else {
                await fixture.editor.importBackupFile(try BackupArchive.zip([
                    ("manifest.json", manifest), ("recordings/song-a/late.m4a", BackupCoreTests.lateTake.audio)
                ]))
            }
            let state = try #require(frozen)
            try clearRetryJournals(beside: recovery)
            try FileManager.default.createDirectory(at: state.folder, withIntermediateDirectories: true)
            try state.audio.write(to: state.folder.appendingPathComponent(state.name))
            try state.journal.write(to: recovery, options: .atomic)
            try await assertOwnerAfterInterveningEdit(harness, recovery: recovery, bytes: state.audio)
            return
        }

        let (harness, recovery, snapshot, take, bytes) = try await singleTakeRecovery(inPlace: cut == "editorInPlace")
        if cut == "beforeIntent" {
            let reopened = try await reopenEditor(harness, recovery: recovery)
            #expect(reopened.audios("reserved") == [bytes])
            #expect(try retryJournals(beside: recovery).isEmpty)
            return
        }
        let staged = snapshot.appendingPathComponent(take.fileName)
        try FileManager.default.removeItem(at: staged)
        var frozen: Data?
        let (first, _) = try await reopenRecoveryEditor(harness, recovery: recovery, save: { context in
            if let journal = try retryJournals(beside: recovery).first,
               try context.fetch(FetchDescriptor<SongProject>()).contains(where: { $0.lyrics == "pending local words" }) {
                frozen = try Data(contentsOf: recovery.deletingLastPathComponent().appendingPathComponent(journal))
                if cut == "rollback" { throw CocoaError(.fileWriteUnknown) }
            }
            try context.save()
        })
        let journal = try #require(frozen)
        try clearRetryJournals(beside: recovery)
        try bytes.write(to: staged)
        if cut == "rollback" {
            for number in [1, 2] {
                let copy = recovery.deletingLastPathComponent().appendingPathComponent("unrecovered-\(number).json")
                try journal.write(to: copy, options: .atomic)
            }
            #expect(try !first.context.fetch(FetchDescriptor<SongProject>()).contains { $0.lyrics == "pending local words" })
            let reopened = try await reopenEditor(first, recovery: recovery)
            #expect(reopened.audios("reserved") == [bytes])
            #expect(try reopened.context.fetch(FetchDescriptor<SongProject>()).filter { $0.lyrics == "pending local words" }.count == 1)
            #expect(try retryJournals(beside: recovery).isEmpty)
        } else {
            try journal.write(to: recovery, options: .atomic)
            try await assertOwnerAfterInterveningEdit(first, recovery: recovery, bytes: bytes)
        }
    }

    @Test(arguments: [false, true])
    func alreadySatisfiedRecoveryStaysAudioOnlyAfterAnEdit(historyUnavailable: Bool) async throws {
        let (harness, recovery, snapshot, take, bytes) = try await singleTakeRecovery(inPlace: true)
        let original = try #require(try harness.context.fetch(FetchDescriptor<SongProject>()).first)
        original.lyrics = "pending local words"
        try harness.context.save()
        let staged = snapshot.appendingPathComponent(take.fileName)
        try FileManager.default.removeItem(at: staged)
        if historyUnavailable {
            var record = try journalObject(Data(contentsOf: recovery))
            record["attempt"] = ["id": UUID().uuidString, "projectId": original.id, "store": "unavailable"]
            try JSONSerialization.data(withJSONObject: record).write(to: recovery, options: .atomic)
        }
        let (first, editor) = try await reopenRecoveryEditor(harness, recovery: recovery)
        let retry = try #require(try retryJournals(beside: recovery).first)
        let retryURL = recovery.deletingLastPathComponent().appendingPathComponent(retry)
        let record = try journalObject(Data(contentsOf: retryURL))
        if historyUnavailable {
            #expect(record["owner"] == nil)
            #expect(record["lyrics"] as? String == "pending local words")
        } else {
            #expect(record["attempt"] == nil)
            #expect(record["owner"] != nil)
        }
        let kept = try #require(try first.context.fetch(FetchDescriptor<SongProject>()).first)
        editor.loadProject(kept)
        editor.lyrics = "words edited after recovery"
        #expect(editor.flushCurrentDraft())
        try bytes.write(to: staged)
        let second = try await reopenEditor(first, recovery: recovery)
        #expect(try second.context.fetch(FetchDescriptor<SongProject>()).map(\.lyrics) == ["words edited after recovery"])
        #expect(second.audios(original.id) == (historyUnavailable ? [] : [bytes]))
        #expect(try retryJournals(beside: recovery).isEmpty == !historyUnavailable)
    }

    @Test(arguments: ["replacement", "trash", "published", "publishedOccupied"])
    func audioRetryRefusesASameIDReplacement(_ path: String) async throws {
        let (harness, recovery, snapshot, take, bytes) = try await singleTakeRecovery()
        let staged = snapshot.appendingPathComponent(take.fileName)
        try FileManager.default.removeItem(at: staged)
        let (first, editor) = try await reopenRecoveryEditor(harness, recovery: recovery)
        let saved = try #require(try first.context.fetch(FetchDescriptor<SongProject>()).first { $0.id == "reserved" })
        let id = saved.id
        let row = try durableRowID(saved)
        var occupantID: String?
        let otherAudio = Data([0x31, 0x64, 0x66])
        if path.hasPrefix("published") {
            let alias = try seedPublishedRecovery(take, bytes: bytes, projectId: id, harness: first, recovery: recovery)
            if path == "publishedOccupied" {
                occupantID = alias
                try first.writeFile(otherAudio, projectId: "original", fileName: "\(alias).m4a")
                first.context.insert(Recording(id: alias, projectId: "original", displayName: "Unrelated.m4a",
                                               audio: otherAudio, recordedAt: Date()))
                try first.context.save()
            }
        }
        if path == "trash" {
            #expect(editor.moveProjectToTrash(saved))
            let trash = try #require(try first.context.fetch(FetchDescriptor<TrashedSongProject>()).first { $0.id == id })
            #expect(editor.restoreTrashedProject(trash) != nil)
        } else {
            let replacement = SongProject(id: id, title: saved.title, lyrics: saved.lyrics, theme: saved.theme)
            first.context.delete(saved)
            try first.context.save()
            first.context.insert(replacement)
            try first.context.save()
        }
        try bytes.write(to: staged)
        let second = try await reopenEditor(first, recovery: recovery)
        let songs = try second.context.fetch(FetchDescriptor<SongProject>())
        #expect(songs.filter { $0.lyrics == "pending local words" }.map(\.id) == [id])
        #expect(try songs.first { $0.id == id }.map(durableRowID) != row)
        #expect(try !second.context.fetch(FetchDescriptor<Recording>()).contains { $0.projectId == id })
        if !path.hasPrefix("published") { #expect(second.audios(id).isEmpty) }
        if let occupantID {
            #expect(second.audios("original") == [otherAudio])
            #expect(try RecordingFiles.readPendingMoves(for: second.memosRoot).adopt.contains { $0.recordingId == occupantID })
            #expect(try second.service.library.liveRecordings(projectId: id, in: second.context).isEmpty)
        }
        #expect(try retryJournals(beside: recovery).count == 1)
    }

    @Test(arguments: [false, true])
    func interruptedOversizedPublicationChecksTheOriginalOwner(replaceOwner: Bool) async throws {
        let (harness, recovery, snapshot, ordinary, _) = try await singleTakeRecovery()
        let bytes = Data(repeating: 0x6c, count: Int(SyncRecording.maxBytes) + 1)
        let take = OpenRecordingSnapshot.Take(fileName: ordinary.fileName, displayName: "Long take.m4a",
            bytes: Int64(bytes.count), sha256: RecordingBackupManifest.sha256Hex(bytes))
        try bytes.write(to: snapshot.appendingPathComponent(take.fileName))
        var journal = try journalObject(Data(contentsOf: recovery))
        journal["recordingTakes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([take]))
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)
        let id = take.recordingID(for: "reserved")
        let target = RecordingFiles.canonicalPath(harness.file(id, "reserved"))
        let hook = RecordingFiles.BoundaryHooks.install { point, _, destination in
            if point == .afterPrimitive, destination.map(RecordingFiles.canonicalPath) == target {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let first: BackupHarness
        do {
            defer { RecordingFiles.BoundaryHooks.remove(hook) }
            first = try await reopenEditor(harness, recovery: recovery)
        }
        #expect(try OversizedRecordings.read(for: first.memosRoot)[id]?.completed == false)
        #expect(try retryJournals(beside: recovery).count == 1)
        let owner = try #require(try first.context.fetch(FetchDescriptor<SongProject>()).first { $0.id == "reserved" })
        let previous = try durableRowID(owner)
        if replaceOwner {
            let replacement = SongProject(id: owner.id, title: owner.title, lyrics: owner.lyrics, theme: owner.theme)
            first.context.delete(owner)
            try first.context.save()
            first.context.insert(replacement)
            try first.context.save()
            #expect(try durableRowID(replacement) != previous)
        }

        let reopened = try await reopenEditor(first, recovery: recovery)
        let entry = try #require(try OversizedRecordings.read(for: reopened.memosRoot)[id])
        #expect(entry.completed == !replaceOwner)
        let playable = try reopened.service.library.liveRecordings(projectId: "reserved", in: reopened.context)
        #expect(try playable.map { try Data(contentsOf: $0.url) } == (replaceOwner ? [] : [bytes]))
        #expect(try retryJournals(beside: recovery).count == (replaceOwner ? 1 : 0))
    }

    @Test(arguments: ["alias", "intent", "blockedAdoption", "adopted"])
    func relaunchAtRecordingPublicationBoundariesKeepsOneVerifiedTake(_ cut: String) async throws {
        let (harness, recovery, snapshot, take, bytes) = try await singleTakeRecovery()
        let staged = snapshot.appendingPathComponent(take.fileName)
        let originalID = take.recordingID(for: "reserved")
        let alternate = UUID().uuidString.lowercased()
        let target = harness.file(alternate, "reserved")
        let occupant = Data([0x61, 0x62])
        try harness.writeFile(occupant, projectId: "reserved", fileName: "\(originalID).m4a")
        var journal = try journalObject(Data(contentsOf: recovery))
        journal["recordingIDs"] = [originalID: alternate]
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)
        if cut != "alias" {
            try harness.service.library.expectCopies([(target, alternate, take.displayName, take.sha256)])
        }
        if cut == "blockedAdoption" {
            let next = try await harness.reopened()
            try next.service.library.expectCopies([(target, alternate, take.displayName, take.sha256)])
            try bytes.write(to: target)
            next.service.library.save = { _ in throw CocoaError(.fileWriteUnknown) }
            let editor = makeRecoveryEditor(next, recovery: recovery)
            await editor.recordingsLaunchTask?.value
            #expect(try retryJournals(beside: recovery).count == 1)
            #expect(FileManager.default.fileExists(atPath: staged.path))
            #expect(try !next.context.fetch(FetchDescriptor<Recording>()).contains { $0.id == alternate })
        } else if cut == "adopted" {
            try bytes.write(to: target)
            try await harness.service.library.reconcile(context: harness.context)
            try FileManager.default.removeItem(at: staged)
        }
        let reopened = try await reopenEditor(harness, recovery: recovery)
        let rows = try reopened.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == "reserved" }
        #expect(rows.filter { $0.audio == bytes }.map(\.id) == [alternate])
        #expect(rows.first { $0.id == originalID }?.audio == occupant)
        #expect(try retryJournals(beside: recovery).isEmpty)
    }

    @Test(arguments: ["take", "song", "published"])
    func pendingAudioDoesNotResurrectADeletedSongOrTake(_ path: String) async throws {
        let (harness, recovery, snapshot, take, bytes) = try await singleTakeRecovery()
        let firstPath = snapshot.appendingPathComponent(take.fileName)
        let other = Data([0x34])
        let secondTake = OpenRecordingSnapshot.Take(fileName: "another.m4a", displayName: "Another.m4a",
            bytes: 1, sha256: RecordingBackupManifest.sha256Hex(other))
        var journal = try journalObject(Data(contentsOf: recovery))
        journal["recordingTakes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([take, secondTake]))
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)
        try FileManager.default.removeItem(at: firstPath)
        let first = try await reopenEditor(harness, recovery: recovery)
        let saved = try #require(try first.context.fetch(FetchDescriptor<SongProject>()).first { $0.id == "reserved" })
        let id = saved.id
        let key = take.recordingID(for: id)
        let date = Date().addingTimeInterval(120).epochMilliseconds
        let deleteSong = path == "song"
        if path == "published" {
            try seedPublishedRecovery(take, bytes: bytes, projectId: id, harness: first, recovery: recovery)
        }
        if deleteSong {
            first.context.delete(saved)
        } else {
            try first.writeFile(Data([0x67]), projectId: id, fileName: "\(key).m4a")
        }
        try DeletionStore.upsert(SyncDeletion(projectId: id, recordingId: deleteSong ? nil : key,
            deletedAt: date), in: first.context)
        try first.context.save()
        try bytes.write(to: firstPath)
        try other.write(to: snapshot.appendingPathComponent(secondTake.fileName))
        let next = try await first.reopened()
        let editor = makeRecoveryEditor(next, recovery: recovery)
        if deleteSong {
            #expect(try !next.context.fetch(FetchDescriptor<SongProject>()).contains { $0.lyrics == "pending local words" })
        }
        await editor.recordingsLaunchTask?.value
        #expect(!next.audios(id).contains(bytes))
        if !deleteSong { #expect(next.audios(id).contains(other)) }
        #expect(try retryJournals(beside: recovery).isEmpty)
        if path == "published" {
            let quarantine = RecordingFiles.quarantineRoot(for: next.memosRoot)
            let paths = try FileManager.default.subpathsOfDirectory(atPath: quarantine.path)
            #expect(paths.contains { (try? Data(contentsOf: quarantine.appendingPathComponent($0))) == bytes })
        } else {
            #expect(try Data(contentsOf: firstPath) == bytes)
        }
    }

    /// Simulates a crash after the verified alias reached the memo folder and before
    /// the recording library adopted it. Write the on-disk intent format directly.
    @discardableResult
    private func seedPublishedRecovery(_ take: OpenRecordingSnapshot.Take, bytes: Data, projectId: String,
                                       harness: BackupHarness, recovery: URL) throws -> String {
        let name = try #require(try retryJournals(beside: recovery).first)
        let retry = recovery.deletingLastPathComponent().appendingPathComponent(name)
        var journal = try journalObject(Data(contentsOf: retry))
        let owner = try #require(journal["owner"] as? [String: Any])
        let row = try #require(owner["row"])
        let original = take.recordingID(for: projectId)
        let alias = UUID().uuidString.lowercased()
        let target = harness.file(alias, projectId)
        try harness.writeFile(bytes, projectId: projectId, fileName: "\(alias).m4a")
        journal["recordingIDs"] = [original: alias]
        try JSONSerialization.data(withJSONObject: journal).write(to: retry, options: .atomic)
        let binding: [String: Any] = [
            "projectId": projectId, "row": row,
            "sourceProjectId": try #require(journal["projectId"]),
            "sourceRecordingId": URL(fileURLWithPath: take.fileName).deletingPathExtension().lastPathComponent,
            "originalId": original, "bytes": take.bytes,
            "precedenceTime": try #require(journal["savedAt"]), "precedenceRepaired": true
        ]
        let move: [String: Any] = [
            "path": RecordingFiles.canonicalPath(target), "recordingId": alias, "displayName": take.displayName,
            "sha256": take.sha256, "draftBinding": binding
        ]
        let moves: [String: Any] = ["adopt": [move], "quarantine": [], "detach": []]
        let quarantine = RecordingFiles.quarantineRoot(for: harness.memosRoot)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: moves)
            .write(to: quarantine.appendingPathComponent("pending-moves.json"), options: .atomic)
        return alias
    }

    @Test func overlappingRecoveryJournalsShareAnAliasWithoutDroppingDrafts() async throws {
        let (harness, recovery, snapshot, take, bytes) = try await singleTakeRecovery()
        let staged = snapshot.appendingPathComponent(take.fileName)
        let initial = try Data(contentsOf: recovery)
        try FileManager.default.removeItem(at: staged)
        let first = try await reopenEditor(harness, recovery: recovery)
        let retry = try #require(try retryJournals(beside: recovery).first)
        let folder = recovery.deletingLastPathComponent()
        let previous = folder.appendingPathComponent(retry)
        var firstDraft = try journalObject(Data(contentsOf: previous))
        var secondDraft = firstDraft
        let key = take.recordingID(for: "reserved")
        let alternate = UUID().uuidString.lowercased()
        firstDraft["recordingIDs"] = [key: alternate]
        let equalBytes = OpenRecordingSnapshot.Take(fileName: "equal.m4a", displayName: "Equal.m4a",
            bytes: take.bytes, sha256: take.sha256)
        secondDraft["recordingTakes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([take, equalBytes]))
        try FileManager.default.removeItem(at: previous)
        try JSONSerialization.data(withJSONObject: firstDraft).write(to: folder.appendingPathComponent("unrecovered-1.json"))
        try JSONSerialization.data(withJSONObject: secondDraft).write(to: folder.appendingPathComponent("unrecovered-2.json"))
        var thirdDraft = try journalObject(initial)
        thirdDraft["lyrics"] = "a different unsaved draft"
        thirdDraft["recordingTakes"] = []
        try JSONSerialization.data(withJSONObject: thirdDraft).write(to: folder.appendingPathComponent("unrecovered-3.json"))
        try first.writeFile(Data([0x67]), projectId: "reserved", fileName: "\(key).m4a")
        try bytes.write(to: staged)
        try bytes.write(to: snapshot.appendingPathComponent(equalBytes.fileName))
        let second = try await reopenEditor(first, recovery: recovery)
        let rows = try second.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == "reserved" && $0.audio == bytes }
        #expect(Set(rows.map(\.id)) == [alternate, equalBytes.recordingID(for: "reserved")])
        let songs = try second.context.fetch(FetchDescriptor<SongProject>())
        #expect(songs.filter { $0.lyrics == "pending local words" }.count == 1)
        #expect(songs.filter { $0.lyrics == "a different unsaved draft" }.count == 1)
        #expect(try retryJournals(beside: recovery).isEmpty)
    }

    @Test(arguments: ["none", "absent", "readable", "unreadable"])
    func legacyDraftJournalKeepsMainRecoveryBehavior(_ folderState: String) async throws {
        let (harness, recovery, snapshot, _, bytes) = try await singleTakeRecovery()
        var journal = try journalObject(Data(contentsOf: recovery))
        journal["recordingTakes"] = nil
        switch folderState {
        case "none":
            journal["recordingSnapshotFolder"] = nil
        case "absent":
            try FileManager.default.removeItem(at: snapshot)
        case "readable":
            try FileManager.default.removeItem(at: snapshot.appendingPathComponent("names.json"))
        default:
            try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: snapshot.path)
        }
        defer {
            if folderState == "unreadable" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshot.path)
            }
        }
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)
        let second = try await reopenEditor(harness, recovery: recovery)
        let kept = try second.context.fetch(FetchDescriptor<SongProject>()).filter { $0.lyrics == "pending local words" }
        #expect(kept.map(\.id) == (folderState == "unreadable" ? [] : ["reserved"]))
        #expect(second.audios("reserved") == (folderState == "readable" ? [bytes] : []))
        #expect(try retryJournals(beside: recovery).count == (folderState == "unreadable" ? 1 : 0))
    }

    private func recoveryURL(_ harness: BackupHarness) -> URL {
        harness.memosRoot.deletingLastPathComponent().appendingPathComponent("draft-recovery.json")
    }

    private func journalObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func durableRowID(_ song: SongProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(song.persistentModelID)
    }

    private func clearRetryJournals(beside recovery: URL) throws {
        for journal in try retryJournals(beside: recovery) {
            try FileManager.default.removeItem(at: recovery.deletingLastPathComponent().appendingPathComponent(journal))
        }
    }

    func singleTakeRecovery(inPlace: Bool = false) async throws
        -> (BackupHarness, URL, URL, OpenRecordingSnapshot.Take, Data) {
        let harness = try await BackupCoreTests().makeHarness()
        let original = SongProject(id: "original", title: "Original", lyrics: inPlace ? "baseline" : "remote words")
        harness.context.insert(original)
        try harness.context.save()
        let bytes = Data([0x35, 0x38])
        try await harness.writeMemo(bytes, projectId: original.id, fileName: "take.m4a")
        let snapshot = try #require(try OpenRecordingSnapshot(projectId: original.id, recordingsRoot: harness.memosRoot))
        let take = try #require(try snapshot.takesForRecovery().first)
        let folder = OpenRecordingSnapshot.stagingRoot(for: harness.memosRoot).appendingPathComponent(snapshot.folderName)
        for row in try harness.context.fetch(FetchDescriptor<Recording>()) { harness.context.delete(row) }
        try harness.context.save()
        try FileManager.default.removeItem(at: harness.memosRoot.appendingPathComponent(original.id))
        let recovery = recoveryURL(harness)
        let journal: [String: Any] = [
            "projectId": original.id, "title": original.title, "lyrics": "pending local words", "theme": "",
            "baselineTitle": original.title, "baselineLyrics": "baseline", "baselineTheme": "",
            "savedAt": Date().timeIntervalSinceReferenceDate, "separateCopyId": "reserved",
            "recordingSnapshotFolder": snapshot.folderName,
            "recordingTakes": try JSONSerialization.jsonObject(with: JSONEncoder().encode([take]))
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: recovery, options: .atomic)
        return (harness, recovery, folder, take, bytes)
    }

    private func assertOwnerAfterInterveningEdit(_ harness: BackupHarness, recovery: URL, bytes: Data) async throws {
        let first = try await harness.reopened()
        let saved = try #require(try first.context.fetch(FetchDescriptor<SongProject>()).first { $0.lyrics == "pending local words" })
        let owner = try durableRowID(saved)
        let id = saved.id
        saved.lyrics = "words edited across the app restart"
        try first.context.save()
        let second = try await reopenEditor(first, recovery: recovery)
        let songs = try second.context.fetch(FetchDescriptor<SongProject>())
        #expect(songs.allSatisfy { $0.lyrics != "pending local words" })
        #expect(try songs.first { $0.id == id }.map(durableRowID) == owner)
        #expect(songs.first { $0.id == id }?.lyrics == "words edited across the app restart")
        #expect(second.audios(id) == [bytes])
        #expect(try retryJournals(beside: recovery).isEmpty)
    }

    private func retryJournals(beside recovery: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: recovery.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("unrecovered-") }
    }

    func reopenEditor(_ harness: BackupHarness, recovery: URL) async throws -> BackupHarness {
        try await reopenRecoveryEditor(harness, recovery: recovery).0
    }

    private func reopenRecoveryEditor(_ harness: BackupHarness, recovery: URL,
                                      save: @escaping (ModelContext) throws -> Void = { try $0.save() })
        async throws -> (BackupHarness, EditorViewModel) {
        let reopened = try await harness.reopened()
        let editor = makeRecoveryEditor(reopened, recovery: recovery, save: save)
        await editor.recordingsLaunchTask?.value
        await editor.waitForRecordingSnapshotSweepForTesting()
        return (reopened, editor)
    }

    private func makeRecoveryEditor(_ reopened: BackupHarness, recovery: URL,
                                    save: @escaping (ModelContext) throws -> Void = { try $0.save() }) -> EditorViewModel {
        let editor = EditorViewModel(
            keychainStore: InMemoryKeychainStore(), backupService: reopened.service,
            recordingLibrary: reopened.service.library, defaults: reopened.defaults, draftRecoveryURL: recovery,
            saveModelContext: save
        )
        editor.modelContext = reopened.context
        return editor
    }

    private typealias PendingFixture = (harness: BackupHarness, editor: EditorViewModel, remote: SyncBlob, audio: Data)

    private func makePendingDraft(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) async throws -> PendingFixture {
        let harness = try await BackupCoreTests().makeHarness()
        let original = SongProject(id: "song-a", title: "Local A", lyrics: "saved local words", theme: "calm")
        let audio = Data([0x31, 0x32, 0x33, 0x34])
        harness.context.insert(original)
        try harness.context.save()
        try await harness.writeMemo(audio, projectId: original.id, fileName: "local-take.m4a")
        let editor = EditorViewModel(
            keychainStore: InMemoryKeychainStore(), backupService: harness.service,
            recordingLibrary: harness.service.library, defaults: harness.defaults,
            draftRecoveryURL: recoveryURL(harness), saveModelContext: save
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
