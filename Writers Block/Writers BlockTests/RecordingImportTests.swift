import AVFoundation
import Foundation
import Testing
@testable import Writers_Block

struct RecordingImportTests {
    private func makeWAV(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Melody.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<4_410 { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test @MainActor func importedAudioSurvivesSourceRemovalRenameTrashRestoreAndBackup() async throws {
        let projectId = "import-test-" + UUID().uuidString
        let sources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: sources)
            VoiceMemoService.deleteMemosFolder(for: projectId)
        }
        let source = try makeWAV(in: sources)
        let original = try Data(contentsOf: source)
        let first = try await VoiceMemoService.importMemo(from: source, projectId: projectId)
        let second = try await VoiceMemoService.importMemo(from: source, projectId: projectId)
        #expect(first != second)
        #expect(first.lastPathComponent == "Melody.wav")
        #expect(second.lastPathComponent == "Melody 2.wav")
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: first) == original)
        #expect(VoiceMemoService.memos(for: projectId).count == 2)
        #expect(try AVAudioFile(forReading: first).length > 0)
        let service = VoiceMemoService()
        let renamed = try service.renameMemo(at: first, to: "Verse idea")
        #expect(renamed.pathExtension == "wav")
        let trash = try #require(service.trashMemo(at: renamed, projectId: projectId))
        #expect(VoiceMemoService.trashedMemos().contains { $0.id == trash.id })
        service.restoreTrashedMemo(trash)
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        let manifest = try RecordingBackupManifest.scan(projectIds: [projectId])
        #expect(manifest.count == 2)
        #expect(manifest.contains { $0.entry.driveName == "rec_\(projectId)_Verse idea.wav.enc" })
        for item in manifest { try item.entry.validate() }
        #expect(service.permissionDenied == false)
    }

    @Test @MainActor func invalidAndCancelledImportsLeaveNoVisibleOrStagedAudio() async throws {
        let projectId = "import-reject-" + UUID().uuidString
        let sources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sources)
            VoiceMemoService.deleteMemosFolder(for: projectId)
        }
        let fake = sources.appendingPathComponent("fake.mp3")
        try Data("This is not audio".utf8).write(to: fake)
        do {
            _ = try await VoiceMemoService.importMemo(from: fake, projectId: projectId)
            Issue.record("Non-audio bytes were accepted")
        } catch { }
        let wav = try makeWAV(in: sources)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VoiceMemoService.importMemo(from: wav, projectId: projectId)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled import was accepted")
        } catch is CancellationError { }
        #expect(VoiceMemoService.memos(for: projectId).isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: VoiceMemoService.memoFolder(for: projectId).path)
        #expect(remaining.isEmpty)
    }

    @Test func backupPreservesEverySupportedExtensionAndRejectsOthers() throws {
        for ext in ["m4a", "mp3", "wav", "aac"] {
            try SyncIdentity.validateFileName("idea.\(ext)")
            #expect(RecordingBackupManifest.driveName(projectId: "song", fileName: "idea.\(ext)") == "rec_song_idea.\(ext).enc")
        }
        #expect(throws: SyncValidationError.invalidFileName) { try SyncIdentity.validateFileName("idea.mp4") }
        #expect(throws: SyncValidationError.invalidFileName) { try SyncIdentity.validateFileName("../idea.wav") }
    }
}
