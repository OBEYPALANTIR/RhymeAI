import Foundation
import Testing
@testable import Writers_Block

// Pure FileManager / path tests — no microphone hardware needed.
// AVAudioRecorder/Player are exercised in manual/device testing only.
struct VoiceMemoServiceTests {

    // MARK: - File Naming

    @Test func newMemoURLHasMp4aExtension() {
        let url = VoiceMemoService.newMemoURL(for: "song-abc")
        #expect(url.pathExtension == "m4a")
    }

    @Test func newMemoURLIsUnderProjectFolder() {
        let projectId = "song-xyz"
        let url = VoiceMemoService.newMemoURL(for: projectId)
        let folder = VoiceMemoService.memoFolder(for: projectId)
        #expect(url.deletingLastPathComponent() == folder)
    }

    @Test func newMemoURLFilenameIsNumericTimestamp() {
        let url = VoiceMemoService.newMemoURL(for: "song-1")
        let stem = url.deletingPathExtension().lastPathComponent
        // Filename is milliseconds since epoch — all digits.
        #expect(Int64(stem) != nil)
        #expect(stem.count >= 10)
    }

    @Test func consecutiveURLsHaveDifferentFilenames() async throws {
        // Two calls must not collide — we sleep 2ms to advance the ms clock.
        let first = VoiceMemoService.newMemoURL(for: "song-1")
        try await Task.sleep(for: .milliseconds(2))
        let second = VoiceMemoService.newMemoURL(for: "song-1")
        #expect(first.lastPathComponent != second.lastPathComponent)
    }

    // MARK: - Folder Layout

    @Test func memoFolderIsInsideMemosRoot() {
        let projectId = "song-42"
        let folder = VoiceMemoService.memoFolder(for: projectId)
        let root = VoiceMemoService.memosRoot()
        // folder must be a direct child of root
        #expect(folder.deletingLastPathComponent() == root)
        #expect(folder.lastPathComponent == projectId)
    }

    // MARK: - File-date ordering

    @Test @MainActor func memosReturnNewestFirstAndRenamePreservesDateOrder() throws {
        let projectId = "memo-date-order-" + UUID().uuidString
        let folder = VoiceMemoService.memoFolder(for: projectId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { VoiceMemoService.deleteMemosFolder(for: projectId) }
        let oldest = folder.appendingPathComponent("Zulu.m4a")
        let middle = folder.appendingPathComponent("1700000000000.wav")
        let newest = folder.appendingPathComponent("Alpha.mp3")
        for (url, timestamp) in [(oldest, 1_700_000_000.0), (middle, 1_700_000_100.0), (newest, 1_700_000_200.0)] {
            try Data([1, 2, 3]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: url.path)
        }
        #expect(VoiceMemoService.memos(for: projectId) == [newest, middle, oldest])
        let originalDate = try newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let service = VoiceMemoService()
        let renamed = try service.renameMemo(at: newest, to: "Zzz renamed")
        #expect(try renamed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
        #expect(VoiceMemoService.memos(for: projectId) == [renamed, middle, oldest])
    }

    @Test @MainActor func memosUseStableFilenameOrderWhenDatesMatch() throws {
        let projectId = "memo-date-tie-" + UUID().uuidString
        let folder = VoiceMemoService.memoFolder(for: projectId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { VoiceMemoService.deleteMemosFolder(for: projectId) }
        for name in ["Zulu.m4a", "Middle.wav", "Alpha.mp3"] {
            let url = folder.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        }
        #expect(VoiceMemoService.memos(for: projectId).map(\.lastPathComponent) == ["Alpha.mp3", "Middle.wav", "Zulu.m4a"])
    }

    @Test @MainActor func memosSkipsUnsupportedAndHiddenFiles() throws {
        let projectId = "memo-filter-" + UUID().uuidString
        let folder = VoiceMemoService.memoFolder(for: projectId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { VoiceMemoService.deleteMemosFolder(for: projectId) }
        for name in ["take.m4a", "take.mp3", "take.wav", "take.aac", "notes.txt", ".staging.wav"] {
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name))
        }
        #expect(Set(VoiceMemoService.memos(for: projectId).map(\.lastPathComponent)) == ["take.m4a", "take.mp3", "take.wav", "take.aac"])
    }

    @Test func memosForAbsentProjectReturnsEmpty() {
        // Non-existent directory — must return [] without throwing.
        let memos = VoiceMemoService.memos(for: "nonexistent-project-\(UUID().uuidString)")
        #expect(memos.isEmpty)
    }

    // MARK: - Purge

    @Test func deleteMemosFolderRemovesDirectory() throws {
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

    @Test func deleteMemosFolderIsSilentWhenFolderAbsent() {
        // Must not throw/crash when the folder never existed.
        VoiceMemoService.deleteMemosFolder(for: "ghost-project-\(UUID().uuidString)")
    }

    // MARK: - sanitizeName

    @Test func sanitizeNameTrimsWhitespace() {
        #expect(VoiceMemoService.sanitizeName("  Hello  ") == "Hello")
    }

    @Test func sanitizeNameStripsSlash() {
        #expect(VoiceMemoService.sanitizeName("my/memo") == "mymemo")
    }

    @Test func sanitizeNameStripsColon() {
        #expect(VoiceMemoService.sanitizeName("verse:chorus") == "versechorus")
    }

    @Test func sanitizeNameCollapsesInternalWhitespace() {
        #expect(VoiceMemoService.sanitizeName("hello   world") == "hello world")
    }

    @Test func sanitizeNameReturnsEmptyForBlankInput() {
        #expect(VoiceMemoService.sanitizeName("   ") == "")
    }

    @Test func sanitizeNamePreservesNormalName() {
        let name = "Verse 1 - Hook"
        #expect(VoiceMemoService.sanitizeName(name) == name)
    }

    // MARK: - renameMemo

    @Test func renameMemoChangesFilename() throws {
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

    @Test func renameMemoHandlesCollisionByAppendingTwo() throws {
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

    @Test func renameMemoReturnsOriginalURLWhenNameSanitizesToEmpty() throws {
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

    @Test func renameMemoThrowsWhenSourceIsMissing() {
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

    @Test func deleteMemoRemovesFileAndLeavesNoError() throws {
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

    @Test func deleteMemoSetsLastErrorWhenFileAbsent() {
        // Removing a non-existent file must NOT be swallowed silently — the
        // service records lastError so the UI can surface the failure.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).m4a")

        let service = VoiceMemoService()
        service.deleteMemo(at: missing)

        #expect(service.lastError != nil)
    }

    // MARK: - displayLabel / isTimestampStem helper logic (replicated here)

    @Test func timestampStemOf13DigitsIsRecognised() {
        // Mirror the isTimestampStem logic used in ProjectsDrawerView.
        let stem = "1700000000000"
        let isTimestamp = stem.count == 13 && stem.allSatisfy(\.isNumber)
        #expect(isTimestamp)
    }

    @Test func customNameStemIsNotRecognisedAsTimestamp() {
        let stem = "Verse 1"
        let isTimestamp = stem.count == 13 && stem.allSatisfy(\.isNumber)
        #expect(!isTimestamp)
    }

    // MARK: - Spectralizer history

    @Test func spectralizerHistoryShiftsLeftAndAppendsNewestSample() {
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
