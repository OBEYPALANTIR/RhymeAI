import AVFoundation
import Foundation
import os
import SwiftData
import Testing
@testable import Writers_Block

// Pure FileManager / path tests — no microphone hardware needed.
// AVAudioRecorder/Player are exercised in manual/device testing only.
struct VoiceMemoServiceTests {

    private final class TransitionEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    @Test func heldDeactivationCompletesBeforeNewPlaybackActivation() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let playbackFinished = DispatchSemaphore(value: 0)
        let events = TransitionEvents()
        let transitions = VoiceMemoAudioSessionTransitions(
            activateRecording: { events.append("record") },
            activatePlayback: { events.append("play") },
            deactivate: {
                events.append("deactivate-start")
                entered.signal()
                release.wait()
                events.append("deactivate-end")
            }
        )

        transitions.deactivate()
        let didEnter = await waitForSignal(entered)
        #expect(didEnter)
        // Enqueue before releasing the held stop; a delayed queue must not let
        // the new activation overtake it.
        transitions.activatePlayback { result in
            if case .failure = result { events.append("play-error") }
            playbackFinished.signal()
        }
        release.signal()
        let didFinish = await waitForSignal(playbackFinished)

        #expect(didFinish)
        #expect(events.snapshot == ["deactivate-start", "deactivate-end", "play"])
    }

    @Test func rapidRecordingPlaybackStopTransitionsRemainOrdered() async throws {
        let events = TransitionEvents()
        let transitions = VoiceMemoAudioSessionTransitions(
            activateRecording: { events.append("record") },
            activatePlayback: { events.append("play") },
            deactivate: { events.append("stop") }
        )

        try await withCheckedThrowingContinuation { continuation in
            transitions.activateRecording { continuation.resume(with: $0) }
        }
        transitions.deactivate()
        try await withCheckedThrowingContinuation { continuation in
            transitions.activatePlayback { continuation.resume(with: $0) }
        }
        transitions.deactivate()
        try await withCheckedThrowingContinuation { continuation in
            transitions.activateRecording { continuation.resume(with: $0) }
        }
        transitions.deactivate()
        try await withCheckedThrowingContinuation { continuation in
            transitions.activatePlayback { continuation.resume(with: $0) }
        }

        #expect(events.snapshot == ["record", "stop", "play", "stop", "record", "stop", "play"])
    }

    @Test @MainActor func stoppingPendingPlaybackInvalidatesItsHeldActivation() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let events = TransitionEvents()
        let transitions = VoiceMemoAudioSessionTransitions(
            activateRecording: { events.append("record") },
            activatePlayback: {
                events.append("play-start")
                entered.signal()
                release.wait()
                events.append("play-end")
            },
            deactivate: {
                events.append("stop")
                stopped.signal()
            }
        )
        let service = VoiceMemoService(sessionTransitions: transitions)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID()).m4a")

        service.togglePlayback(url: url)
        let didEnter = await waitForSignal(entered)
        #expect(didEnter)
        service.stopPlayback()
        release.signal()
        let didStop = await waitForSignal(stopped)

        #expect(didStop)
        #expect(events.snapshot == ["play-start", "play-end", "stop"])
        #expect(!service.isPlaying)
        #expect(!service.isPlayingMemo(at: url))
    }

    // MARK: - File Naming

    @Test func newMemoURLHasMp4aExtension() async {
        let url = RecordingFiles.newMemoURL(for: "song-abc")
        #expect(url.pathExtension == "m4a")
    }

    @Test func newMemoURLIsUnderProjectFolder() async {
        let projectId = "song-xyz"
        let url = RecordingFiles.newMemoURL(for: projectId)
        let folder = RecordingFiles.memoFolder(for: projectId)
        #expect(url.deletingLastPathComponent() == folder)
    }

    @Test func newMemoURLFilenameIsNumericTimestamp() async {
        let url = RecordingFiles.newMemoURL(for: "song-1")
        let stem = url.deletingPathExtension().lastPathComponent
        // Filename is milliseconds since epoch — all digits.
        #expect(Int64(stem) != nil)
        #expect(stem.count >= 10)
    }

    @Test func consecutiveURLsHaveDifferentFilenames() async throws {
        // Two calls must not collide — we sleep 2ms to advance the ms clock.
        let first = RecordingFiles.newMemoURL(for: "song-1")
        try await Task.sleep(for: .milliseconds(2))
        let second = RecordingFiles.newMemoURL(for: "song-1")
        #expect(first.lastPathComponent != second.lastPathComponent)
    }

    // MARK: - Folder Layout

    @Test func memoFolderIsInsideMemosRoot() async {
        let projectId = "song-42"
        let folder = RecordingFiles.memoFolder(for: projectId)
        let root = RecordingFiles.memosRoot()
        // folder must be a direct child of root
        #expect(folder.deletingLastPathComponent() == root)
        #expect(folder.lastPathComponent == projectId)
    }

    // MARK: - Listing sorted by name (= creation date)

    @Test func memosReturnsSortedByFilename() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write three files with timestamps in non-sequential write order.
        let names = ["1000.m4a", "3000.m4a", "2000.m4a"]
        for name in names {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }

        // Stub: temporarily redirect memosRoot isn't possible without DI, so
        // test the sort logic directly against the raw FileManager call that
        // memos(for:) mirrors.
        let items = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        .filter { $0.pathExtension == "m4a" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let sorted = items.map { $0.deletingPathExtension().lastPathComponent }
        #expect(sorted == ["1000", "2000", "3000"])
    }

    @Test func memosSkipsNonM4aFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["1000.m4a", "readme.txt", "2000.wav", "3000.m4a"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }

        let items = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        .filter { $0.pathExtension == "m4a" }

        #expect(items.count == 2)
    }

    // MARK: - Purge

    /// T1.4: a song's recording folder is removed only once empty; nothing in it is
    /// removed by folder.
    @Test func aTrashFolderIsRemovedOnlyWhenEmpty() async throws {
        let folder = RecordingFiles.trashFolder(for: "purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        try Data([1]).write(to: file)

        RecordingFiles.removeEmptyFolder(folder, within: RecordingFiles.memosTrashRoot())
        #expect(try Data(contentsOf: file) == Data([1]))

        try FileManager.default.removeItem(at: file)
        RecordingFiles.cleanUpEmptyTrashFolder(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - sanitizeName

    @Test func sanitizeNameTrimsWhitespace() async {
        #expect(RecordingFiles.sanitizeName("  Hello  ") == "Hello")
    }

    @Test func sanitizeNameStripsSlash() async {
        #expect(RecordingFiles.sanitizeName("my/memo") == "mymemo")
    }

    @Test func sanitizeNameStripsColon() async {
        #expect(RecordingFiles.sanitizeName("verse:chorus") == "versechorus")
    }

    @Test func sanitizeNameCollapsesInternalWhitespace() async {
        #expect(RecordingFiles.sanitizeName("hello   world") == "hello world")
    }

    @Test func sanitizeNameReturnsEmptyForBlankInput() async {
        #expect(RecordingFiles.sanitizeName("   ") == "")
    }

    @Test func sanitizeNamePreservesNormalName() async {
        let name = "Verse 1 - Hook"
        #expect(RecordingFiles.sanitizeName(name) == name)
    }

    // MARK: - renameMemo

    @Test func renameMemoReturnsOriginalURLWhenNameSanitizesToEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameMemoEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("1700000000002.m4a")
        FileManager.default.createFile(atPath: source.path, contents: Data())

        let service = VoiceMemoService()
        let result = try service.renameMemo(at: source, to: "  /  ")

        // Empty after sanitize → no-op, original URL returned.
        #expect(result == source)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func renameMemoThrowsWhenSourceIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")

        let service = VoiceMemoService()
        do {
            _ = try service.renameMemo(at: missing, to: "Verse 1")
            Issue.record("Expected renameMemo to throw for a missing source file")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    // MARK: - displayLabel / isTimestampStem helper logic (replicated here)

    @Test func timestampStemOf13DigitsIsRecognised() async {
        // Mirror the isTimestampStem logic used in ProjectsDrawerView.
        let stem = "1700000000000"
        let isTimestamp = stem.count == 13 && stem.allSatisfy(\.isNumber)
        #expect(isTimestamp)
    }

    @Test func customNameStemIsNotRecognisedAsTimestamp() async {
        let stem = "Verse 1"
        let isTimestamp = stem.count == 13 && stem.allSatisfy(\.isNumber)
        #expect(!isTimestamp)
    }

    // MARK: - Spectralizer history

    @Test func spectralizerHistoryShiftsLeftAndAppendsNewestSample() async {
        var history = Array(repeating: Float(0), count: 22)
        history[0] = -1

        for sample in [Float(0.1), 0.4, 0.9] {
            history.removeFirst()
            history.append(sample)
        }

        #expect(history.count == 22)
        #expect(!history.contains(-1))
        #expect(history[19] == 0.1)
        #expect(history[20] == 0.4)
        #expect(history[21] == 0.9)
    }
}

/// Finished takes whose publication failed stay recoverable (A27/A31).
@MainActor
struct PendingTakeTests {
    private struct Store {
        let scratch: URL
        let context: ModelContext
        let container: ModelContainer
        let library: RecordingLibrary
        let stagingRoot: URL
    }

    private func makeStore() async throws -> Store {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PendingTakes-\(UUID().uuidString)", isDirectory: true)
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: scratch.appendingPathComponent("library.store"), cloudKitDatabase: .none)])
        let library = RecordingLibrary(memosRoot: scratch.appendingPathComponent("voice-memos", isDirectory: true),
                                       trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "PendingTakes-\(scratch.lastPathComponent)")!)
        library.context = container.mainContext
        try await library.reconcile(context: container.mainContext)
        return Store(scratch: scratch, context: container.mainContext, container: container, library: library,
                     stagingRoot: scratch.appendingPathComponent("recording-in-progress", isDirectory: true))
    }

    /// The same on-disk store, files and settings opened afresh, as after the app was killed.
    private func reopen(_ store: Store) throws -> Store {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: store.scratch.appendingPathComponent("library.store"), cloudKitDatabase: .none)])
        let library = RecordingLibrary(memosRoot: store.library.memosRoot, trashRoot: store.library.trashRoot,
                                       defaults: UserDefaults(suiteName: "PendingTakes-\(store.scratch.lastPathComponent)")!)
        library.context = container.mainContext
        return Store(scratch: store.scratch, context: container.mainContext, container: container, library: library, stagingRoot: store.stagingRoot)
    }

    /// A take's audio in its own folder, as the recorder leaves it.
    private func take(_ audio: Data, in store: Store, finishedAt: Date? = nil) throws -> URL {
        let url = RecordingFiles.recorderStagingURL(for: "song", takeId: UUID().uuidString.lowercased(), root: store.stagingRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audio.write(to: url)
        if let finishedAt { try RecordingFiles.writeFinishedMarker(finishedAt, in: url.deletingLastPathComponent()) }
        return url
    }

    @Test func finishedTakesWaitAcrossRelaunchAndRetrySavesEachOnceByIdWithItsFinishTime() async throws {
        let store = try await makeStore()
        store.library.save = { _ in throw CocoaError(.fileWriteUnknown) }
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        service.publishRecording(try take(Data([1, 1]), in: store), projectId: "song")
        #expect(service.pendingTakes.count == 1 && service.lastError != nil)
        // The app stopped right after another take finished at a known time.
        let orphan = try take(Data([2, 2]), in: store, finishedAt: Date(timeIntervalSince1970: 1_234))

        // A real relaunch: store, settings and library opened afresh (T6.46).
        let reopened = try reopen(store)
        try await reopened.library.reconcile(context: reopened.context)
        let relaunched = VoiceMemoService(stagingRoot: store.stagingRoot)
        relaunched.publisher = reopened.library
        let ids = Set(relaunched.pendingTakes.map(\.id))
        #expect(ids.count == 2 && ids.contains(orphan.deletingLastPathComponent().lastPathComponent))
        await relaunched.retryPendingTakes()
        #expect(relaunched.pendingTakes.isEmpty && relaunched.failedTakes.isEmpty)
        let afterRetry = try reopen(store)
        let rows = try afterRetry.context.fetch(FetchDescriptor<Recording>())
        for row in rows { #expect(try Data(contentsOf: store.library.memosRoot.appendingPathComponent("song/\(row.id).m4a")) == row.audio) }
        #expect(Set(rows.map(\.id)) == ids)
        // The retry reuses the recorded finish time, never the retry time.
        #expect(rows.first { $0.id == orphan.deletingLastPathComponent().lastPathComponent }?.uploadedAt == Date(timeIntervalSince1970: 1_234))

        // A take published before the app stopped (its marker still there) counts as saved.
        let published = try #require(ids.first)
        let folder = store.stagingRoot.appendingPathComponent("song/\(published)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingFiles.writeFinishedMarker(Date(), in: folder)
        let again = VoiceMemoService(stagingRoot: store.stagingRoot)
        again.publisher = reopened.library
        #expect(again.pendingTakes.map(\.id) == [published])
        await again.retryPendingTakes()
        #expect(again.pendingTakes.isEmpty && again.lastError == nil)
        let final = try reopen(store)
        #expect(try final.context.fetch(FetchDescriptor<Recording>()).count == 2)
    }

    /// T3.10: a take an earlier build left flat in its song's staging folder moves
    /// into its own folder, named by its new id, with its bytes, and waits there.
    @Test func aFlatTakeFromAnEarlierBuildMovesIntoItsOwnFolder() async throws {
        let store = try await makeStore()
        let flat = store.stagingRoot.appendingPathComponent("song/take.m4a")
        try FileManager.default.createDirectory(at: flat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([3, 1, 4]).write(to: flat)

        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library

        let pending = try #require(service.pendingTakes.first)
        #expect(service.pendingTakes.count == 1 && !FileManager.default.fileExists(atPath: flat.path))
        let moved = store.stagingRoot.appendingPathComponent("song/\(pending.id)/\(pending.id).m4a")
        #expect(try Data(contentsOf: moved) == Data([3, 1, 4]))
    }

    /// T3.11: an empty finished marker (as earlier builds wrote it) means its own
    /// write time, which is then written into it.
    @Test func anEmptyFinishedMarkerIsReadAsItsWriteTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent(RecordingFiles.finishedTakeMarker)
        try Data().write(to: marker)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234)], ofItemAtPath: marker.path)

        #expect(RecordingFiles.readFinishedMarker(in: folder) == Date(timeIntervalSince1970: 1_234))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "1234000")
        // A value that is not a plausible time is not a time.
        try Data("99999999999999999".utf8).write(to: marker)
        #expect(RecordingFiles.readFinishedMarker(in: folder) == nil)
    }

    @Test func aFailureAfterTheMoveKeepsTheRowAndTheMarker() async throws {
        let store = try await makeStore()
        var saves = 0
        // The row and its intent save; clearing the intent after the move fails.
        store.library.save = { context in
            saves += 1
            if saves > 1 { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        let staged = try take(Data([5, 5]), in: store)
        service.publishRecording(staged, projectId: "song")

        let id = staged.deletingLastPathComponent().lastPathComponent
        #expect(service.pendingTakes.map(\.id) == [id] && service.lastError != nil)
        // What was saved survives a relaunch: the row with its audio, and the file (T6.47).
        let reopened = try reopen(store)
        let row = try #require(try reopened.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id == id && row.audio == Data([5, 5]))
        #expect(try Data(contentsOf: store.library.memosRoot.appendingPathComponent("song/\(id).m4a")) == Data([5, 5]))
        try await reopened.library.reconcile(context: reopened.context)
        let relaunched = VoiceMemoService(stagingRoot: store.stagingRoot)
        relaunched.publisher = reopened.library
        await relaunched.retryPendingTakes()
        #expect(relaunched.pendingTakes.isEmpty && relaunched.failedTakes.isEmpty)
        #expect(try reopened.context.fetch(FetchDescriptor<Recording>()).map(\.id) == [id])
    }

    @Test func renamingChangesTheDisplayNameAndLeavesTheFile() async throws {
        let store = try await makeStore()
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        let staged = try take(Data([3, 3]), in: store)
        service.publishRecording(staged, projectId: "song")
        let id = staged.deletingLastPathComponent().lastPathComponent
        let file = store.library.memosRoot.appendingPathComponent("song/\(id).m4a")

        #expect(try service.renameMemo(at: file, to: "Verse 1") == file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let row = try #require(store.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.displayName == "Verse 1.m4a" && row.displayNameChanged)
    }

    @Test func anUnmarkedTakeIsPublishedOnlyWhenItsContainerIsFinished() async throws {
        let store = try await makeStore()
        let fixtures = try await AudioFixtures.make(in: store.scratch)
        let complete = try take(fixtures.complete, in: store)
        let cutMidData = try take(fixtures.truncatedMidData, in: store)
        let cutAfterIndex = try take(fixtures.truncatedAfterIndex, in: store)
        let cutBeforeIndex = try take(fixtures.truncatedBeforeIndex, in: store)

        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        #expect(service.pendingTakes.count == 4)
        await service.retryPendingTakes()

        #expect(try store.context.fetch(FetchDescriptor<Recording>()).map(\.id) == [complete.deletingLastPathComponent().lastPathComponent])
        #expect(Set(service.failedTakes.map(\.id)) == Set([cutMidData, cutAfterIndex, cutBeforeIndex].map { $0.deletingLastPathComponent().lastPathComponent }))
        #expect(service.pendingTakes.isEmpty)
        for kept in [cutMidData, cutAfterIndex, cutBeforeIndex] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
    }

    @Test func containerCheckReadsEverySample() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fixtures = try await AudioFixtures.make(in: scratch)
        func check(_ data: Data) async throws -> RecordingFiles.ContainerCheck {
            let url = scratch.appendingPathComponent("\(UUID().uuidString).m4a")
            try data.write(to: url)
            return await RecordingFiles.checkFinishedContainer(url)
        }
        #expect(try await check(fixtures.complete) == .complete)
        #expect(try await check(fixtures.indexFirst) == .complete)
        #expect(try await check(fixtures.truncatedMidData) == .invalid)
        #expect(try await check(fixtures.truncatedAfterIndex) == .invalid)
        #expect(try await check(fixtures.truncatedBeforeIndex) == .invalid)
        #expect(await RecordingFiles.checkFinishedContainer(scratch.appendingPathComponent("absent.m4a")) == .uninspectable)
    }

    @Test func anOversizedTakeKeepsItsIdentityThroughACrashAfterTheMove() async throws {
        let store = try await makeStore()
        let staged = try take(Data(count: Int(SyncRecording.maxBytes) + 1), in: store, finishedAt: Date(timeIntervalSince1970: 77))
        let id = staged.deletingLastPathComponent().lastPathComponent
        let published = try store.library.publishFinished(staged, projectId: "song", preferredName: staged.lastPathComponent, origin: .recorded, id: id, finishedAt: Date(timeIntervalSince1970: 77))
        // The app stopped after the move and before the record was completed (T6.50):
        // the record still names its source, and the take's marker is still there.
        var entry = try #require(OversizedRecordings.read(for: store.library.memosRoot)[id])
        entry.source = staged.path
        entry.completed = false
        try OversizedRecordings.record(id: id, entry: entry, for: store.library.memosRoot)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RecordingFiles.writeFinishedMarker(Date(timeIntervalSince1970: 77), in: staged.deletingLastPathComponent())
        let reopened = try reopen(store)
        try await reopened.library.reconcile(context: reopened.context)
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = reopened.library
        #expect(service.pendingTakes.map(\.id) == [id])
        await service.retryPendingTakes()
        #expect(service.pendingTakes.isEmpty && service.failedTakes.isEmpty && service.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: published.path))
        let finished = try #require(OversizedRecordings.read(for: store.library.memosRoot)[id])
        #expect(finished.finishedAt == 77_000 && finished.completed == true)
    }

    @Test func anOversizedTakeInterruptedBetweenItsJournalAndItsMoveIsFinished() async throws {
        let store = try await makeStore()
        let staged = try take(Data(count: Int(SyncRecording.maxBytes) + 1), in: store, finishedAt: Date(timeIntervalSince1970: 88))
        let id = staged.deletingLastPathComponent().lastPathComponent
        // The app stopped right after journalling the publication (with the take's
        // digest and length, T1.16), before the move.
        try OversizedRecordings.record(id: id, entry: .init(projectId: "song", fileName: staged.lastPathComponent, finishedAt: 88_000,
                                                             source: staged.path, completed: false, sha256: RecordingFiles.sha256(of: staged),
                                                             bytes: RecordingFiles.facts(staged).size), for: store.library.memosRoot)
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        await service.retryPendingTakes()

        let destination = store.library.memosRoot.appendingPathComponent("song/\(id).m4a")
        #expect(FileManager.default.fileExists(atPath: destination.path) && !FileManager.default.fileExists(atPath: staged.path))
        #expect(service.pendingTakes.isEmpty && service.failedTakes.isEmpty)
        #expect(try OversizedRecordings.read(for: store.library.memosRoot)[id]?.completed == true)
    }

    @Test func anOversizedTakeNeverCountsAnotherFileAtItsPlaceAsItself() async throws {
        let store = try await makeStore()
        let staged = try take(Data(repeating: 7, count: Int(SyncRecording.maxBytes) + 1), in: store, finishedAt: Date(timeIntervalSince1970: 99))
        let id = staged.deletingLastPathComponent().lastPathComponent
        try OversizedRecordings.record(id: id, entry: .init(projectId: "song", fileName: staged.lastPathComponent, finishedAt: 99_000, source: staged.path,
                                                             completed: false, sha256: try RecordingFiles.sha256(of: staged)), for: store.library.memosRoot)
        // Something else took its place before the move.
        let place = store.library.memosRoot.appendingPathComponent("song/\(id).m4a")
        try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: Int(SyncRecording.maxBytes) + 1).write(to: place)

        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        await service.retryPendingTakes()

        // The take waits with its bytes where they were; the other file is untouched.
        let entry = try #require(OversizedRecordings.read(for: store.library.memosRoot)[id])
        #expect(entry.completed == false)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: place).first == 1)
        #expect(service.pendingTakes.map(\.id) == [id])
    }

    @Test func takesThatCannotBeListedOrReadStayWaiting() async throws {
        let store = try await makeStore()
        let unreadable = try take(Data([1, 2]), in: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        #expect(await RecordingFiles.checkFinishedContainer(unreadable) == .uninspectable)

        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        await service.retryPendingTakes()
        #expect(service.pendingTakes.map(\.id) == [unreadable.deletingLastPathComponent().lastPathComponent] && service.failedTakes.isEmpty)

        // A folder that cannot be listed keeps the takes already known.
        let project = store.stagingRoot.appendingPathComponent("song")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: project.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path) }
        service.refreshPendingTakes()
        #expect(service.pendingTakesUnreadable && service.pendingTakes.count == 1)
    }

    @Test func aDeletedRecordingIsNotPlayed() async {
        let service = VoiceMemoService(stagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        service.playbackAllowed = { _ in false }
        service.togglePlayback(url: URL(fileURLWithPath: "/tmp/song/take.m4a"))
        #expect(!service.isPlaying && service.lastError == "This recording was deleted and can't be played.")
    }
}

/// Real AAC recordings written by the system encoder, and cut-off copies.
enum AudioFixtures {
    struct Set {
        /// Index (moov) after the audio, as the recorder writes it.
        let complete: Data
        /// The same audio with its index first.
        let indexFirst: Data
        /// Index-first, cut in the middle of the audio data.
        let truncatedMidData: Data
        /// Index-first, cut just after the index, before most of the audio.
        let truncatedAfterIndex: Data
        /// Index-last, cut before the index was written.
        let truncatedBeforeIndex: Data
    }

    /// A real AAC recording of the given length (a quiet tone).
    static func long(seconds: Int, at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for frame in 0..<44_100 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 220 / 44_100)) * 0.05 }
        for _ in 0..<seconds { try file.write(from: buffer) }
    }

    static func make(in folder: URL) async throws -> Set {
        let recorded = folder.appendingPathComponent("recorded.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: recorded, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            for frame in 0..<44_100 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100)) * 0.5 }
            try file.write(from: buffer)
        }
        let indexFirstURL = folder.appendingPathComponent("index-first.m4a")
        let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: recorded), presetName: AVAssetExportPresetPassthrough))
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: indexFirstURL, as: .m4a)
        let complete = try Data(contentsOf: recorded)
        let indexFirst = try Data(contentsOf: indexFirstURL)
        let mdat = try #require(indexFirst.range(of: Data("mdat".utf8)))
        let moov = try #require(indexFirst.range(of: Data("moov".utf8)))
        #expect(moov.lowerBound < mdat.lowerBound)
        let dataStart = mdat.upperBound
        return Set(
            complete: complete,
            indexFirst: indexFirst,
            truncatedMidData: indexFirst.prefix(dataStart + (indexFirst.count - dataStart) / 2),
            truncatedAfterIndex: indexFirst.prefix(dataStart + 16),
            truncatedBeforeIndex: complete.prefix(complete.count * 3 / 5)
        )
    }
}

/// Round 14: takes and imports interrupted or challenged by the production code.
extension PendingTakeTests {
    /// T1.16: a take whose id already has a row is settled only by a recoverable
    /// published copy; a row whose audio is not its recorded bytes and has no file
    /// keeps the staged take waiting.
    @Test func aTakeWhoseRowHoldsNoRecoverableCopyKeepsItsStagedAudio() async throws {
        let store = try await makeStore()
        let staged = try take(Data([4, 4]), in: store, finishedAt: Date(timeIntervalSince1970: 50))
        let id = staged.deletingLastPathComponent().lastPathComponent
        // A row from an earlier attempt, whose audio is damaged and whose file is gone.
        store.context.insert(Recording(id: id, projectId: "song", displayName: "take.m4a", audio: Data([0]), recordedAt: Date(timeIntervalSince1970: 50),
                                       sha256: RecordingBackupManifest.sha256Hex(Data([4, 4]))))
        try store.context.save()
        try await store.library.reconcile(context: store.context)
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library

        await service.retryPendingTakes()

        #expect(try Data(contentsOf: staged) == Data([4, 4]))
        #expect(service.pendingTakes.map(\.id) == [id])
    }

    /// T6.50: an oversized take killed after its move and before its record was
    /// completed is finished from the record after a relaunch.
    @Test func anOversizedTakeKilledAfterItsMoveIsCompletedAfterARelaunch() async throws {
        let store = try await makeStore()
        let staged = try take(Data(repeating: 2, count: Int(SyncRecording.maxBytes) + 1), in: store, finishedAt: Date(timeIntervalSince1970: 66))
        let id = staged.deletingLastPathComponent().lastPathComponent
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        try await withBoundaryHook(scope: store.scratch, { point, source, _ in
            // After the rename, before the record is marked done: the process stops.
            if point == .afterPrimitive, source.lastPathComponent == staged.lastPathComponent { throw SimulatedCrash() }
        }) {
            await service.retryPendingTakes()
        }
        let place = store.library.memosRoot.appendingPathComponent("song/\(id).m4a")
        #expect(FileManager.default.fileExists(atPath: place.path) && !FileManager.default.fileExists(atPath: staged.path))
        #expect(try OversizedRecordings.read(for: store.library.memosRoot)[id]?.completed == false)

        let reopened = try reopen(store)
        try await reopened.library.reconcile(context: reopened.context)
        let relaunched = VoiceMemoService(stagingRoot: store.stagingRoot)
        relaunched.publisher = reopened.library
        await relaunched.retryPendingTakes()

        let entry = try #require(OversizedRecordings.read(for: store.library.memosRoot)[id])
        #expect(entry.completed == true && entry.finishedAt == 66_000)
        #expect(relaunched.pendingTakes.isEmpty && relaunched.failedTakes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: place.path))
    }

    /// T5.11: an unreadable marker is set aside and the take's own audio decides:
    /// complete audio is published, a malformed container is kept as failed.
    @Test func anUnreadableMarkerIsSetAsideAndTheAudioDecides() async throws {
        let store = try await makeStore()
        let fixtures = try await AudioFixtures.make(in: store.scratch)
        let good = try take(fixtures.complete, in: store)
        let bad = try take(fixtures.truncatedMidData, in: store)
        for staged in [good, bad] {
            try Data("not a time".utf8).write(to: staged.deletingLastPathComponent().appendingPathComponent(RecordingFiles.finishedTakeMarker))
        }
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library

        await service.retryPendingTakes()

        let goodId = good.deletingLastPathComponent().lastPathComponent
        #expect(try store.context.fetch(FetchDescriptor<Recording>()).map(\.id) == [goodId])
        #expect(service.failedTakes.map(\.id) == [bad.deletingLastPathComponent().lastPathComponent])
        #expect(try Data(contentsOf: bad) == fixtures.truncatedMidData)
        let aside = try FileManager.default.contentsOfDirectory(atPath: bad.deletingLastPathComponent().path)
        #expect(aside.contains { $0.hasPrefix("finished.unreadable-") })
    }

    /// T5.12: only a take that could not be saved can be deleted, and only when asked.
    @Test func onlyAFailedTakeIsDeletedOnRequest() async throws {
        let store = try await makeStore()
        let fixtures = try await AudioFixtures.make(in: store.scratch)
        let bad = try take(fixtures.truncatedMidData, in: store)
        let waiting = try take(Data([1, 2, 3]), in: store, finishedAt: Date(timeIntervalSince1970: 9))
        store.library.save = { _ in throw CocoaError(.fileWriteUnknown) }
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        await service.retryPendingTakes()
        let failed = try #require(service.failedTakes.first)
        let pending = try #require(service.pendingTakes.first { $0.id == waiting.deletingLastPathComponent().lastPathComponent })

        service.deleteFailedTake(pending)
        #expect(FileManager.default.fileExists(atPath: waiting.path), "a take waiting to be saved is never deleted")
        service.deleteFailedTake(failed)
        #expect(!FileManager.default.fileExists(atPath: bad.deletingLastPathComponent().path))
        #expect(service.failedTakes.isEmpty)
    }

    /// T1.21, T1.22: an import is staged as `<id>/<id>.<ext>` beside its record; one
    /// killed just before publication is published under that id at the next launch.
    @Test func anImportKilledBeforePublicationIsPublishedUnderItsIdAtLaunch() async throws {
        let store = try await makeStore()
        let fixtures = try await AudioFixtures.make(in: store.scratch)
        let source = store.scratch.appendingPathComponent("Voice Note.m4a")
        try fixtures.complete.write(to: source)
        let importRoot = store.scratch.appendingPathComponent("recording-import", isDirectory: true)
        let crashImage = store.scratch.appendingPathComponent("import-at-crash", isDirectory: true)
        let staged = HookBox<(id: String, record: VoiceMemoService.ImportRecord?)?>(nil)
        try await withBoundaryHook(scope: importRoot, { point, source, _ in
            guard point == .beforeCheck, staged.value == nil else { return }
            let folder = source.deletingLastPathComponent()
            let record = try? JSONDecoder().decode(VoiceMemoService.ImportRecord.self, from: Data(contentsOf: folder.appendingPathComponent("import.json")))
            staged.value = (folder.lastPathComponent, record)
            // What the disk holds at this instant is what a killed app leaves.
            try FileManager.default.copyItem(at: importRoot, to: crashImage)
            throw SimulatedCrash()
        }) {
            _ = try? await VoiceMemoService.importMemo(from: source, projectId: "song", publisher: store.library, importRoot: importRoot)
        }
        let id = try #require(staged.value?.id)
        #expect(staged.value?.record?.id == id && staged.value?.record?.verified == true && staged.value?.record?.displayName == "Voice Note.m4a")
        #expect(FileManager.default.fileExists(atPath: crashImage.appendingPathComponent("\(id)/\(id).m4a").path))
        // The relaunch finds the crash image.
        try? FileManager.default.removeItem(at: importRoot)
        try FileManager.default.moveItem(at: crashImage, to: importRoot)
        let reopened = try reopen(store)
        try await reopened.library.reconcile(context: reopened.context)

        let kept = await VoiceMemoService.recoverImports(publisher: reopened.library, importRoot: importRoot)

        #expect(kept.isEmpty)
        let row = try #require(try reopened.context.fetch(FetchDescriptor<Recording>()).first { $0.id == id })
        #expect(row.displayName == "Voice Note.m4a")
        try await reopened.library.reconcile(context: reopened.context)
        #expect(try Data(contentsOf: reopened.library.memosRoot.appendingPathComponent("song/\(id).m4a")) == fixtures.complete)
        #expect(!FileManager.default.fileExists(atPath: importRoot.appendingPathComponent(id).path))
    }

    /// T4.6: recovery never touches the folder of an import still running here; a
    /// folder no running import owns and whose copy never decoded is disposed of.
    @Test func importRecoveryLeavesARunningImportAlone() async throws {
        let store = try await makeStore()
        let importRoot = store.scratch.appendingPathComponent("recording-import", isDirectory: true)
        func folder(_ id: String) throws -> URL {
            let folder = importRoot.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try VoiceMemoService.ImportRecord(id: id, projectId: "song", displayName: "a.m4a", verified: false).write(in: folder)
            try Data([1]).write(to: folder.appendingPathComponent("\(id).m4a"))
            return folder
        }
        let running = UUID().uuidString.lowercased(), abandoned = UUID().uuidString.lowercased()
        let runningFolder = try folder(running), abandonedFolder = try folder(abandoned)
        VoiceMemoService.activeImports.withLock { _ = $0.insert(running) }
        defer { VoiceMemoService.activeImports.withLock { _ = $0.remove(running) } }

        await VoiceMemoService.recoverImports(publisher: store.library, importRoot: importRoot)

        #expect(FileManager.default.fileExists(atPath: runningFolder.appendingPathComponent("\(running).m4a").path))
        #expect(!FileManager.default.fileExists(atPath: abandonedFolder.path))
    }
}
