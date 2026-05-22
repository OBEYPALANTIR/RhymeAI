import Foundation
import UIKit

enum LyricsExporter {
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
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
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
                let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
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
}
