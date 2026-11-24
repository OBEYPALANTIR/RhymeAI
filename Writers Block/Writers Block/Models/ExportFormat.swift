import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt
    case json
    case pdf
    case lrc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .txt: return "Plain Text"
        case .json: return "Project JSON"
        case .pdf: return "Lyric Sheet (PDF)"
        case .lrc: return "Timed Lyrics (.lrc)"
        }
    }

    var description: String {
        switch self {
        case .txt: return "Lyrics only. Universal."
        case .json: return "Title, lyrics, theme. Re-importable."
        case .pdf: return "Print-ready formatted sheet."
        case .lrc: return "DAW/player format. Empty timestamps for now."
        }
    }

    var iconSystemName: String {
        switch self {
        case .txt: return "doc.text"
        case .json: return "doc.badge.gearshape"
        case .pdf: return "doc.richtext"
        case .lrc: return "music.note.list"
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .txt: return .plainText
        case .json: return .json
        case .pdf: return .pdf
        case .lrc: return UTType(filenameExtension: "lrc") ?? .data
        }
    }
}

struct SongProjectExport: Codable, Sendable {
    var id: String
    var title: String
    var lyrics: String
    var theme: String
    var updatedAt: Date

    init(from project: SongProject) {
        self.id = project.id
        self.title = project.title
        self.lyrics = project.lyrics
        self.theme = project.theme
        self.updatedAt = project.updatedAt
    }
}

/// Owns the source ZIP until the system exporter finishes copying it.
nonisolated final class BackupExportFile: Transferable {
    // Launch and every export share this once-per-process initialization.
    static let temporaryRoot = prepareTemporaryRoot(in: FileManager.default.temporaryDirectory)

    static func prepareTemporaryRoot(in temporaryDirectory: URL) -> URL {
        let root = temporaryDirectory.appendingPathComponent("writersblock-export", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return root
    }

    let url: URL
    var fileName: String { url.lastPathComponent }

    init(now: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = Self.temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("WritersBlock-backup-\(formatter.string(from: now)).zip")
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    deinit { removeTemporaryFiles() }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { SentTransferredFile($0.url) }
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .json, .pdf, .zip]
        if let lrc = UTType(filenameExtension: "lrc") { types.append(lrc) }
        return types
    }
    static var writableContentTypes: [UTType] { readableContentTypes }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = raw
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
