import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

        let titleFont = pdfFont("Times-Bold", size: 22)
        let themeFont = pdfFont("Times-Italic", size: 11)
        let bodyFont = pdfFont("Times-Roman", size: 12)
        let sectionFont = pdfFont("Times-Bold", size: 12)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: PlatformColor(white: 0.07, alpha: 1)
        ]
        let themeAttrs: [NSAttributedString.Key: Any] = [
            .font: themeFont,
            .foregroundColor: PlatformColor(white: 0.4, alpha: 1)
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor(white: 0.07, alpha: 1)
        ]
        let sectionAttrs: [NSAttributedString.Key: Any] = [
            .font: sectionFont,
            .foregroundColor: PlatformColor(white: 0.2, alpha: 1)
        ]

        let lineHeight: CGFloat = 18
        return renderPDF(pageSize: CGSize(width: pageWidth, height: pageHeight)) { beginPage in
            beginPage()
            var y = marginY

            let titleString = (project.title.isEmpty ? "Untitled" : project.title) as NSString
            titleString.draw(at: CGPoint(x: marginX, y: y), withAttributes: titleAttrs)
            y += Self.lineHeight(of: titleFont) + 6

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
                    beginPage()
                    y = marginY
                }
                if line.isEmpty {
                    y += lineHeight
                    continue
                }
                let isSection = line.hasPrefix("[") && line.hasSuffix("]")
                let attrs = isSection ? sectionAttrs : bodyAttrs
                let storage = NSTextStorage(string: line, attributes: attrs)
                let layout = NSLayoutManager()
                let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                let glyphs = layout.glyphRange(for: container)
                let height = max(layout.usedRect(for: container).height, lineHeight)
                // Keep ordinary lyric lines together; paginate oversized lines by their rendered fragments.
                if height <= pageHeight - marginY * 2 && y + height > pageHeight - marginY {
                    beginPage()
                    y = marginY
                }
                var drawnHeight: CGFloat = 0
                layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
                    if y + rect.height > pageHeight - marginY {
                        beginPage()
                        y = marginY
                    }
                    layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: marginX, y: y - rect.minY))
                    y += rect.height
                    drawnHeight += rect.height
                }
                y += max(0, lineHeight - drawnHeight)
            }
        }
    }

    #if canImport(UIKit)
    private static func pdfFont(_ name: String, size: CGFloat) -> UIFont {
        UIFont(descriptor: UIFontDescriptor(name: name, size: size), size: size)
    }

    private static func lineHeight(of font: UIFont) -> CGFloat { font.lineHeight }

    private static func renderPDF(pageSize: CGSize, draw: (_ beginPage: @escaping () -> Void) -> Void) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { ctx in
            draw { ctx.beginPage() }
        }
    }
    #else
    private static func pdfFont(_ name: String, size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }

    private static func lineHeight(of font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// The AppKit counterpart of `UIGraphicsPDFRenderer`: top-left origin pages,
    /// so the same drawing code lays out both platforms' PDFs.
    private static func renderPDF(pageSize: CGSize, draw: (_ beginPage: @escaping () -> Void) -> Void) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        var pageOpen = false
        draw {
            if pageOpen { context.endPDFPage() }
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            pageOpen = true
        }
        if pageOpen { context.endPDFPage() }
        context.closePDF()
        NSGraphicsContext.restoreGraphicsState()
        return data as Data
    }
    #endif

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
