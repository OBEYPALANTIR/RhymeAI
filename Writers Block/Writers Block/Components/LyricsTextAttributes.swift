import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#endif

struct LyricsRewriteHighlight: Equatable {
    let range: NSRange
    let isLoading: Bool
    let isError: Bool
    var isInsertion: Bool = false
}

/// The lyrics editor's attribute work, shared by the UITextView (iOS) and
/// NSTextView (macOS) editors. Both run TextKit 2, so word colours are
/// rendering attributes on the `NSTextLayoutManager` and syllable underlines
/// live on the `NSTextStorage`.
enum LyricsTextAttributes {
    /// The underline attributes kept on the text storage. Neither changes
    /// glyph advances, so line breaks and the caret do not move.
    static let underlineAttributeKeys: [NSAttributedString.Key] = [.underlineStyle, .underlineColor]

    private struct Underline: Equatable {
        let range: NSRange
        let color: PlatformColor
    }

    /// `sectionLabelForeground` draws section header lines ("[Verse 1]",
    /// "[Chorus]") in a quieter neutral ink. It is a rendering attribute
    /// only: the stored text, its brackets, glyph metrics, selection and
    /// undo are untouched. Header lines carry no analysis spans, and spans
    /// are applied after it, so no lyric word loses its syllable or rhyme
    /// colour.
    static func applyRenderingColors(
        _ spans: [LyricsColorSpan],
        text: String,
        storageLength: Int,
        layout: NSTextLayoutManager,
        foreground: PlatformColor,
        sectionLabelForeground: PlatformColor?
    ) {
        let sectionLabelRanges = sectionLabelForeground == nil ? [] : SectionMap.headerRanges(text)
        guard let content = layout.textContentManager else { return }
        layout.renderingAttributesValidator = nil
        layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
        layout.invalidateRenderingAttributes(for: content.documentRange)
        let render: (NSTextLayoutManager, NSTextRange) -> Void = { layout, target in
            guard let content = layout.textContentManager else { return }
            layout.setRenderingAttributes([.foregroundColor: foreground], for: target)
            let start = content.offset(from: content.documentRange.location, to: target.location)
            let end = content.offset(from: content.documentRange.location, to: target.endLocation)
            let targetRange = NSRange(location: start, length: end - start)
            if let sectionLabelForeground {
                for header in sectionLabelRanges {
                    let intersection = NSIntersectionRange(header, targetRange)
                    guard intersection.length > 0,
                          let lower = content.location(content.documentRange.location, offsetBy: intersection.location),
                          let upper = content.location(lower, offsetBy: intersection.length),
                          let textRange = NSTextRange(location: lower, end: upper) else { continue }
                    layout.setRenderingAttributes([.foregroundColor: sectionLabelForeground], for: textRange)
                }
            }
            for span in spans {
                let intersection = NSIntersectionRange(span.range, targetRange)
                guard intersection.length > 0,
                      let lower = content.location(content.documentRange.location, offsetBy: intersection.location),
                      let upper = content.location(lower, offsetBy: intersection.length),
                      let textRange = NSTextRange(location: lower, end: upper) else { continue }
                layout.setRenderingAttributes(
                    [.foregroundColor: span.foreground.map(PlatformColor.init) ?? foreground],
                    for: textRange
                )
            }
        }
        layout.renderingAttributesValidator = { layout, fragment in
            render(layout, fragment.rangeInElement)
        }
        if storageLength > 0 { render(layout, content.documentRange) }
    }

    /// Writes each span's syllable underline to the text storage and removes
    /// the ones no span asks for, so turning a guide off leaves nothing
    /// behind. Returns false, touching nothing, when the storage already
    /// holds exactly the wanted underlines. Only the plain text is ever
    /// published, saved or exported, and an attribute change is not a user
    /// edit: no delegate callback, no undo entry.
    @discardableResult
    static func applyUnderlines(_ spans: [LyricsColorSpan], to storage: NSTextStorage) -> Bool {
        let full = NSRange(location: 0, length: storage.length)

        let wanted: [Underline] = spans.compactMap { span in
            let range = NSIntersectionRange(span.range, full)
            guard range.length > 0, let underline = span.underline else { return nil }
            return Underline(range: range, color: PlatformColor(underline))
        }.sorted { $0.range.location < $1.range.location }

        var present: [Underline] = []
        var unexpected = false
        storage.enumerateAttributes(in: full) { attributes, range, _ in
            let style = attributes[.underlineStyle] as? Int
            let color = attributes[.underlineColor] as? PlatformColor
            guard style != nil || color != nil else { return }
            if style == NSUnderlineStyle.single.rawValue, let color {
                present.append(Underline(range: range, color: color))
            } else {
                unexpected = true
            }
        }
        guard unexpected || present != wanted else { return false }

        storage.beginEditing()
        for key in underlineAttributeKeys {
            storage.removeAttribute(key, range: full)
        }
        for underline in wanted {
            storage.addAttributes(
                [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: underline.color],
                range: underline.range
            )
        }
        storage.endEditing()
        return true
    }

    /// Text typed next to an underlined word must not inherit the underline.
    static func removingUnderline(
        from typingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any]? {
        guard underlineAttributeKeys.contains(where: { typingAttributes[$0] != nil }) else { return nil }
        var attributes = typingAttributes
        for key in underlineAttributeKeys {
            attributes.removeValue(forKey: key)
        }
        return attributes
    }

    /// Moves the applied spans across one user edit so colours stay on their
    /// words until the next analysis lands. Returns nil when the edit does not
    /// explain `newText` (the spans would land on the wrong characters).
    static func spansAfterEdit(
        _ spans: [LyricsColorSpan],
        source: String,
        range: NSRange,
        replacement: String,
        newText: String
    ) -> [LyricsColorSpan]? {
        guard range.location <= source.utf16.count,
              range.length <= source.utf16.count - range.location else { return nil }
        let expectedText = (source as NSString).replacingCharacters(in: range, with: replacement)
        guard expectedText == newText else { return nil }
        let replacementLength = replacement.utf16.count
        let editEnd = NSMaxRange(range)
        let delta = replacementLength - range.length
        var adjusted: [LyricsColorSpan] = []
        adjusted.reserveCapacity(spans.count + 1)

        for span in spans {
            let spanEnd = NSMaxRange(span.range)
            if spanEnd <= range.location {
                adjusted.append(span)
            } else if span.range.location >= editEnd {
                adjusted.append(LyricsColorSpan(
                    range: NSRange(location: span.range.location + delta, length: span.range.length),
                    foreground: span.foreground,
                    underline: span.underline
                ))
            } else {
                let prefixLength = max(range.location - span.range.location, 0)
                if prefixLength > 0 {
                    adjusted.append(LyricsColorSpan(
                        range: NSRange(location: span.range.location, length: prefixLength),
                        foreground: span.foreground,
                        underline: span.underline
                    ))
                }
                let suffixLength = max(spanEnd - editEnd, 0)
                if suffixLength > 0 {
                    adjusted.append(LyricsColorSpan(
                        range: NSRange(location: range.location + replacementLength, length: suffixLength),
                        foreground: span.foreground,
                        underline: span.underline
                    ))
                }
            }
        }
        return adjusted
    }
}

/// Platform-neutral parts of the lyrics editor representable; the view itself
/// is a UITextView on iOS (`LyricsTextView.swift`) and an NSTextView on macOS
/// (`LyricsTextView+macOS.swift`).
extension LyricsTextView {
    var renderedText: String {
        displayText ?? text
    }

    /// The animation a highlight clear may fade on: the transaction's own, or
    /// none when animations are disabled (Reduce Motion) or absent.
    static func highlightClearAnimation(for transaction: Transaction) -> Animation? {
        transaction.disablesAnimations ? nil : transaction.animation
    }

    /// Only a cleared "Use line" mark fades; the rewrite highlight clears in one frame.
    static func fadesOnClear(previous: LyricsRewriteHighlight?, next: LyricsRewriteHighlight?) -> Bool {
        next == nil && previous?.isInsertion == true
    }

    var activeHighlight: LyricsRewriteHighlight? {
        rewriteHighlight ?? insertionHighlight.map {
            LyricsRewriteHighlight(range: $0, isLoading: false, isError: false, isInsertion: true)
        }
    }
}

/// Colours for the pending-rewrite and insertion highlight, taken from the
/// appearance palette so the editor stays monochrome while a rewrite is in
/// flight. The overlay sits above the text, so the fill stays translucent.
struct RewriteHighlightColors: Equatable {
    static let pendingFillOpacity: CGFloat = 0.45
    static let pendingStrokeOpacity: CGFloat = 0.90
    static let errorFillOpacity: CGFloat = 0.20
    static let errorStrokeOpacity: CGFloat = 0.60
    static let insertionFillOpacity: CGFloat = 0.12
    static let insertionStrokeOpacity: CGFloat = 0.45

    let fill: PlatformColor
    let stroke: PlatformColor

    /// A selection waiting for, or receiving, a rewrite: the editor's own
    /// selection tint with a strong-outline border. Nothing moves.
    static func pending(palette: AppAppearancePalette) -> RewriteHighlightColors {
        RewriteHighlightColors(
            fill: PlatformColor(palette.selectionTint).withAlphaComponent(pendingFillOpacity),
            stroke: PlatformColor(palette.outlineStrong).withAlphaComponent(pendingStrokeOpacity)
        )
    }

    static func error(palette: AppAppearancePalette) -> RewriteHighlightColors {
        RewriteHighlightColors(
            fill: PlatformColor(palette.error).withAlphaComponent(errorFillOpacity),
            stroke: PlatformColor(palette.error).withAlphaComponent(errorStrokeOpacity)
        )
    }

    static func insertion(palette: AppAppearancePalette) -> RewriteHighlightColors {
        RewriteHighlightColors(
            fill: PlatformColor(palette.primaryInk).withAlphaComponent(insertionFillOpacity),
            stroke: PlatformColor(palette.primaryInk).withAlphaComponent(insertionStrokeOpacity)
        )
    }

    static func forHighlight(_ highlight: LyricsRewriteHighlight, palette: AppAppearancePalette) -> RewriteHighlightColors {
        if highlight.isInsertion { return insertion(palette: palette) }
        if highlight.isError { return error(palette: palette) }
        return pending(palette: palette)
    }
}
