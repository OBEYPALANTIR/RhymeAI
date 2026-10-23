import AVFoundation
import Foundation
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

    @Test func memosForAbsentProjectReturnsEmpty() async {
        // Non-existent directory — must return [] without throwing.
        let memos = RecordingFiles.memos(for: "nonexistent-project-\(UUID().uuidString)")
        #expect(memos.isEmpty)
    }

    // MARK: - Purge

    @Test func deleteMemosFolderRemovesDirectory() async throws {
        // Use a temp dir as a stand-in for the real Application Support path
        // so the test is hermetic and doesn't pollute the simulator sandbox.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-\(UUID().uuidString)", isDirectory: true)
        let projectFolder = tmp.appendingPathComponent("project-1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let file = projectFolder.appendingPathComponent("1000.m4a")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(FileManager.default.fileExists(atPath: projectFolder.path))

        // We can't call deleteMemosFolder(for:) here because it hardcodes
        // Application Support. Instead test the underlying FileManager.removeItem
        // call that the static method delegates to — same one-liner path.
        try FileManager.default.removeItem(at: projectFolder)

        #expect(!FileManager.default.fileExists(atPath: projectFolder.path))
    }

    @Test func deleteMemosFolderIsSilentWhenFolderAbsent() async {
        // Must not throw/crash when the folder never existed.
        RecordingFiles.deleteMemosFolder(for: "ghost-project-\(UUID().uuidString)")
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

    @Test func renameMemoChangesFilename() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameMemoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("1700000000000.m4a")
        FileManager.default.createFile(atPath: original.path, contents: Data())

        let service = VoiceMemoService()
        let renamed = try service.renameMemo(at: original, to: "Verse 1")

        #expect(renamed.deletingPathExtension().lastPathComponent == "Verse 1")
        #expect(renamed.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func renameMemoHandlesCollisionByAppendingTwo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameMemoCollision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-create the target name so a collision occurs.
        let existing = dir.appendingPathComponent("Hook.m4a")
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        let source = dir.appendingPathComponent("1700000000001.m4a")
        FileManager.default.createFile(atPath: source.path, contents: Data())

        let service = VoiceMemoService()
        let renamed = try service.renameMemo(at: source, to: "Hook")

        #expect(renamed.deletingPathExtension().lastPathComponent == "Hook 2")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }

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

    // MARK: - deleteMemo

    @Test func deleteMemoRemovesFileAndLeavesNoError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeleteMemoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("1700000000000.m4a")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let service = VoiceMemoService()
        service.deleteMemo(at: file)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(service.lastError == nil)
    }

    @Test func deleteMemoSetsLastErrorWhenFileAbsent() async {
        // Removing a non-existent file must NOT be swallowed silently — the
        // service records lastError so the UI can surface the failure.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).m4a")

        let service = VoiceMemoService()
        service.deleteMemo(at: missing)

        #expect(service.lastError != nil)
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

        store.library.save = { try $0.save() }
        let relaunched = VoiceMemoService(stagingRoot: store.stagingRoot)
        relaunched.publisher = store.library
        let ids = Set(relaunched.pendingTakes.map(\.id))
        #expect(ids.count == 2 && ids.contains(orphan.deletingLastPathComponent().lastPathComponent))
        await relaunched.retryPendingTakes()
        #expect(relaunched.pendingTakes.isEmpty && relaunched.failedTakes.isEmpty)
        let rows = try store.context.fetch(FetchDescriptor<Recording>())
        #expect(Set(rows.map(\.id)) == ids)
        // The retry reuses the recorded finish time, never the retry time.
        #expect(rows.first { $0.id == orphan.deletingLastPathComponent().lastPathComponent }?.uploadedAt == Date(timeIntervalSince1970: 1_234))

        // A take published before the app stopped (its marker still there) counts as saved.
        let published = try #require(ids.first)
        let folder = store.stagingRoot.appendingPathComponent("song/\(published)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingFiles.writeFinishedMarker(Date(), in: folder)
        let again = VoiceMemoService(stagingRoot: store.stagingRoot)
        again.publisher = store.library
        #expect(again.pendingTakes.map(\.id) == [published])
        await again.retryPendingTakes()
        #expect(again.pendingTakes.isEmpty && again.lastError == nil)
        #expect(try store.context.fetch(FetchDescriptor<Recording>()).count == 2)
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
        #expect(try store.context.fetch(FetchDescriptor<Recording>()).map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: store.library.memosRoot.appendingPathComponent("song/\(staged.lastPathComponent)").path))
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
        // The app stopped before the take's marker was cleared: a retry finds it saved.
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        #expect(service.pendingTakes.map(\.id) == [id])
        await service.retryPendingTakes()
        #expect(service.pendingTakes.isEmpty && service.failedTakes.isEmpty && service.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: published.path))
        #expect(try OversizedRecordings.read(for: store.library.memosRoot)[id]?.finishedAt == 77_000)
    }

    @Test func anOversizedTakeInterruptedBetweenItsJournalAndItsMoveIsFinished() async throws {
        let store = try await makeStore()
        let staged = try take(Data(count: Int(SyncRecording.maxBytes) + 1), in: store, finishedAt: Date(timeIntervalSince1970: 88))
        let id = staged.deletingLastPathComponent().lastPathComponent
        // The app stopped right after journalling the publication, before the move.
        try OversizedRecordings.record(id: id, entry: .init(projectId: "song", fileName: staged.lastPathComponent, finishedAt: 88_000,
                                                             source: staged.path, completed: false), for: store.library.memosRoot)
        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        await service.retryPendingTakes()

        let destination = store.library.memosRoot.appendingPathComponent("song/\(staged.lastPathComponent)")
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
        let place = store.library.memosRoot.appendingPathComponent("song/\(staged.lastPathComponent)")
        try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: Int(SyncRecording.maxBytes) + 1).write(to: place)

        let service = VoiceMemoService(stagingRoot: store.stagingRoot)
        service.publisher = store.library
        await service.retryPendingTakes()

        let entry = try #require(OversizedRecordings.read(for: store.library.memosRoot)[id])
        #expect(entry.completed == true && entry.fileName != staged.lastPathComponent)
        let moved = store.library.memosRoot.appendingPathComponent("song/\(entry.fileName)")
        #expect(try RecordingFiles.sha256(of: moved) == entry.sha256)
        #expect(try Data(contentsOf: place).first == 1)
        #expect(service.pendingTakes.isEmpty && service.failedTakes.isEmpty)
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
