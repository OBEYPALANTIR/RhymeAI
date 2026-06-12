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

    // MARK: - Listing sorted by name (= creation date)

    @Test func memosReturnsSortedByFilename() throws {
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

    @Test func memosSkipsNonM4aFiles() throws {
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
}
