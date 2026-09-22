import Foundation
import Darwin
import UIKit

enum LyricsExporter {
    // Matches Android document imports; recordings have their own 100 MiB limit.
    nonisolated static let maximumProjectImportBytes = 10 * 1_024 * 1_024

    enum ImportError: LocalizedError, Equatable {
        case notARegularFile, fileTooLarge, fileChanged

        var errorDescription: String? {
            switch self {
            case .notARegularFile: "The selected item is not a project file."
            case .fileTooLarge: "This project file is larger than 10 MiB."
            case .fileChanged: "The selected project file changed while it was being read. Try again."
            }
        }
    }

    nonisolated static func decodeJsonExport(
        from url: URL,
        didReadChunk: (@Sendable (Int) async throws -> Void)? = nil
    ) async throws -> SongProjectExport {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Nonblocking open lets us reject FIFOs/devices without waiting for input.
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                path.map { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
            }
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            let opened = try projectImportStatus(descriptor)
            var data = Data()
            data.reserveCapacity(Int(opened.st_size))
            while data.count <= maximumProjectImportBytes {
                try Task.checkCancellation()
                let count = min(64 * 1_024, maximumProjectImportBytes + 1 - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= maximumProjectImportBytes else { throw ImportError.fileTooLarge }
                // A deterministic read checkpoint for concurrent-change/cancellation tests.
                try await didReadChunk?(data.count)
            }
            try Task.checkCancellation()
            let finished = try projectImportStatus(descriptor)
            var pathStatus = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                path.map { fstatat(AT_FDCWD, $0, &pathStatus, 0) } ?? -1
            }
            guard result == 0,
                  stableProjectImport(opened, finished),
                  stableProjectImport(finished, pathStatus),
                  finished.st_size == off_t(data.count) else { throw ImportError.fileChanged }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let exported = try decoder.decode(SongProjectExport.self, from: data)
            try Task.checkCancellation()
            return exported
        }
        return try await withTaskCancellationHandler {
            let exported = try await worker.value
            try Task.checkCancellation()
            return exported
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func projectImportStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ImportError.notARegularFile
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumProjectImportBytes) else {
            throw ImportError.fileTooLarge
        }
        return status
    }

    nonisolated private static func stableProjectImport(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_size == after.st_size && before.st_mode == after.st_mode &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func data(for project: SongProject, format: ExportFormat) throws -> Data {
        switch format {
        case .txt: return buildTxt(project)
        case .json: return try buildJson(project)
        case .pdf: return buildPdf(project)
        case .lrc: return buildLrc(project)
        }
    }

    static func decodeJsonExport(_ data: Data) throws -> SongProjectExport {
        return try jsonDecoder.decode(SongProjectExport.self, from: data)
    }

    private static func buildTxt(_ project: SongProject) -> Data {
        let title = project.title.isEmpty ? "Untitled" : project.title
        var header = title
        if !project.theme.isEmpty {
            header += "\nTheme: \(project.theme)"
        }
        header += "\n\n"
        return Data((header + project.lyrics).utf8)
    }

    private static func buildJson(_ project: SongProject) throws -> Data {
        let dto = SongProjectExport(from: project)
        return try jsonEncoder.encode(dto)
    }

    private static func buildLrc(_ project: SongProject) -> Data {
        let title = project.title.isEmpty ? "Untitled" : project.title
        var sb = ""
        sb += "[ti:\(title)]\n"
        sb += "[ar:Unknown]\n"
        sb += "[al:RhymeAI]\n"
        sb += "[length:00:00.00]\n\n"
        for raw in project.lyrics.components(separatedBy: "\n") {
            let line = trimmingTrailingHorizontalWhitespace(raw)
            if line.isEmpty {
                sb += "\n"
            } else {
                sb += "[00:00.00]\(line)\n"
            }
        }
        return Data(sb.utf8)
    }

    private static func buildPdf(_ project: SongProject) -> Data {
        let pageWidth: CGFloat = 612   // 8.5" * 72
        let pageHeight: CGFloat = 792  // 11"  * 72
        let marginX: CGFloat = 54
        let marginY: CGFloat = 54
        let maxWidth = pageWidth - marginX * 2

        let titleFont = UIFont(descriptor: UIFontDescriptor(name: "Times-Bold", size: 22), size: 22)
        let themeFont = UIFont(descriptor: UIFontDescriptor(name: "Times-Italic", size: 11), size: 11)
        let bodyFont = UIFont(descriptor: UIFontDescriptor(name: "Times-Roman", size: 12), size: 12)
        let sectionFont = UIFont(descriptor: UIFontDescriptor(name: "Times-Bold", size: 12), size: 12)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor(white: 0.07, alpha: 1)
        ]
        let themeAttrs: [NSAttributedString.Key: Any] = [
            .font: themeFont,
            .foregroundColor: UIColor(white: 0.4, alpha: 1)
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor(white: 0.07, alpha: 1)
        ]
        let sectionAttrs: [NSAttributedString.Key: Any] = [
            .font: sectionFont,
            .foregroundColor: UIColor(white: 0.2, alpha: 1)
        ]

        let lineHeight: CGFloat = 18
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y = marginY

            let titleString = (project.title.isEmpty ? "Untitled" : project.title) as NSString
            titleString.draw(at: CGPoint(x: marginX, y: y), withAttributes: titleAttrs)
            y += titleFont.lineHeight + 6

            if !project.theme.isEmpty {
                let themeString = "Theme: \(project.theme)" as NSString
                let bounds = themeString.boundingRect(
                    with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    attributes: themeAttrs,
                    context: nil
                )
                themeString.draw(
                    with: CGRect(x: marginX, y: y, width: maxWidth, height: bounds.height),
                    options: [.usesLineFragmentOrigin],
                    attributes: themeAttrs,
                    context: nil
                )
                y += max(bounds.height, lineHeight) + 6
            }
            y += lineHeight

            for raw in project.lyrics.components(separatedBy: "\n") {
                let line = trimmingTrailingHorizontalWhitespace(raw)
                if y > pageHeight - marginY {
                    ctx.beginPage()
                    y = marginY
                }
                if line.isEmpty {
                    y += lineHeight
                    continue
                }
                let isSection = line.hasPrefix("[") && line.hasSuffix("]")
                let attrs = isSection ? sectionAttrs : bodyAttrs
                let nsLine = line as NSString
                let bounds = nsLine.boundingRect(
                    with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    attributes: attrs,
                    context: nil
                )
                let drawHeight = max(bounds.height, lineHeight)
                if y + drawHeight > pageHeight - marginY {
                    ctx.beginPage()
                    y = marginY
                }
                nsLine.draw(
                    with: CGRect(x: marginX, y: y, width: maxWidth, height: drawHeight),
                    options: [.usesLineFragmentOrigin],
                    attributes: attrs,
                    context: nil
                )
                y += drawHeight
            }
        }
    }

    private static func trimmingTrailingHorizontalWhitespace(_ value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let previous = value.index(before: end)
            if value[previous] == " " || value[previous] == "\t" {
                end = previous
            } else {
                break
            }
        }
        return String(value[..<end])
    }
}
