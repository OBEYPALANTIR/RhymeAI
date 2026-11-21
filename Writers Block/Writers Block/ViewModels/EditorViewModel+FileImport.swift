import Foundation
import UniformTypeIdentifiers

/// File imports shared by the songs drawer, the recordings sheet and the Mac
/// window's drop target, so each entry point reads files the same way.
extension EditorViewModel {
    /// Audio a recording can be imported from.
    static let importableAudioTypes: [UTType] = [.mpeg4Audio, .mp3, .wav, UTType(filenameExtension: "aac") ?? .audio]

    /// Reads a RhymeAI song JSON export and opens it as a song. Throws when the
    /// file cannot be read or is not a song export; false means the import was
    /// refused after reading (the outgoing draft could not be kept).
    func importSongFile(at url: URL) throws -> Bool {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let exported = try LyricsExporter.decodeJsonExport(data)
        return importProject(exported)
    }

    /// Copies an audio file into a song's recordings.
    func importRecording(at url: URL, projectId: String) async throws {
        _ = try await VoiceMemoService.importMemo(from: url, projectId: projectId, publisher: voiceMemoService.publisher)
        voiceMemoService.onFilesChanged?()
    }
}
