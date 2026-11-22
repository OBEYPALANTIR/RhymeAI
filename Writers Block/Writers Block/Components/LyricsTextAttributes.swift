import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformView = UIView
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformView = NSView
#endif

// The lyrics editor's platform-neutral logic, shared by the UITextView editor
// (iOS, `LyricsTextView.swift`) and the NSTextView editor (macOS,
// `LyricsTextView+macOS.swift`). Both run TextKit 2: word colours are
// rendering attributes on the `NSTextLayoutManager`, and the syllable
// underline is drawn by `SyllableUnderlineView` from the laid-out frames.

struct LyricsRewriteHighlight: Equatable {
    let range: NSRange
    let isLoading: Bool
    let isError: Bool
    var isInsertion: Bool = false
}

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

extension LyricsTextView.Coordinator {
    /// The spans after a user edit and, for each previous span start, its
    /// start now. `pending` is the edit the delegate announced; when it does
    /// not explain `text`, the edit is read off the two texts instead.
    static func spansAfterEdit(
        _ spans: [LyricsColorSpan],
        source: String,
        pending: (source: String, range: NSRange, replacement: String)?,
        text: String
    ) -> (spans: [LyricsColorSpan], locations: [Int: Int]) {
        if let pending, pending.source == source,
           NSMaxRange(pending.range) <= source.utf16.count,
           (source as NSString).replacingCharacters(in: pending.range, with: pending.replacement) == text {
            return spansMoved(spans, by: pending.range, replacement: pending.replacement)
        }
        return spansMoved(spans, from: source, to: text)
    }

    /// The one replacement that turns `old` into `new`. Marked text,
    /// dictation and some system edits change the text without asking the
    /// delegate first, so the edit is read off the two texts.
    static func edit(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        let before = Array(old.utf16)
        let after = Array(new.utf16)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let replacement = (new as NSString).substring(with: NSRange(location: prefix, length: after.count - prefix - suffix))
        return (NSRange(location: prefix, length: before.count - prefix - suffix), replacement)
    }

    /// Moves the spans across an edit read off the two texts. The region
    /// between their common prefix and suffix, widened to whole words, can
    /// hold several separate edits (two words edited, a split and a join,
    /// an autocorrection and a space). Unchanged words there keep their
    /// spans first; in each gap between them, each old span keeps the
    /// characters that survive, and each new word takes the colours of the
    /// spans whose characters it holds. A new word holding none waits for
    /// the analysis.
    static func spansMoved(
        _ spans: [LyricsColorSpan],
        from old: String,
        to new: String
    ) -> (spans: [LyricsColorSpan], locations: [Int: Int]) {
        let edit = edit(from: old, to: new)
        let oldText = old as NSString
        let newText = new as NSString
        func isWordUnit(_ unit: unichar) -> Bool {
            (65...90).contains(unit) || (97...122).contains(unit) || unit == 39 || unit == 0x2019 || unit == 0x02BC
        }
        var start = edit.range.location
        var oldEnd = NSMaxRange(edit.range)
        var newEnd = start + (edit.replacement as NSString).length
        while start > 0, isWordUnit(oldText.character(at: start - 1)) { start -= 1 }
        while oldEnd < oldText.length, isWordUnit(oldText.character(at: oldEnd)) {
            oldEnd += 1
            newEnd += 1
        }
        let delta = newText.length - oldText.length

        var adjusted: [(source: Int, span: LyricsColorSpan)] = []
        var replaced: [LyricsColorSpan] = []
        for span in spans {
            if NSMaxRange(span.range) <= start {
                adjusted.append((span.range.location, span))
            } else if span.range.location >= oldEnd {
                adjusted.append((span.range.location, LyricsColorSpan(
                    range: NSRange(location: span.range.location + delta, length: span.range.length),
                    foreground: span.foreground,
                    underline: span.underline
                )))
            } else {
                replaced.append(span)
            }
        }
        let words = LyricRegex.word.matches(in: new, range: NSRange(location: start, length: newEnd - start)).map(\.range)
        // The old text's own words, each carrying the spans inside it (one
        // per word after an analysis, or the fragments an edit left).
        let oldWords = LyricRegex.word.matches(in: old, range: NSRange(location: start, length: oldEnd - start)).map(\.range)
        var wordSpans = Array(repeating: [(source: Int, span: LyricsColorSpan)](), count: oldWords.count)
        var first = 0
        for (index, word) in oldWords.enumerated() {
            while first < replaced.count, NSMaxRange(replaced[first].range) <= word.location { first += 1 }
            var next = first
            while next < replaced.count, replaced[next].range.location < NSMaxRange(word) {
                let inside = NSIntersectionRange(replaced[next].range, word)
                if inside.length > 0 {
                    wordSpans[index].append((replaced[next].range.location, replaced[next].with(range: inside)))
                }
                next += 1
            }
        }
        let before = oldWords.map { oldText.substring(with: $0) }
        let after = words.map { newText.substring(with: $0) }

        // Unchanged words anchor first (`anchoredWords`); each keeps its
        // spans, and their layers, at its new place.
        // Too large to align: only the region's common prefix and suffix
        // survive, nothing is stretched, and the rest waits for the analysis.
        guard let anchors = anchoredWords(before, at: oldWords, after, at: words) else {
            let surviving = survivingPieces(
                replaced.map { ($0.range.location, $0) },
                old: oldText, in: NSRange(location: start, length: oldEnd - start),
                new: newText, in: NSRange(location: start, length: newEnd - start),
                aligns: false
            )
            for word in words {
                for piece in surviving.pieces {
                    let kept = NSIntersectionRange(piece.span.range, word)
                    if kept.length > 0 { adjusted.append((piece.source, piece.span.with(range: kept))) }
                }
            }
            adjusted.sort { $0.span.range.location < $1.span.range.location }
            return clipped(adjusted)
        }
        for (oldIndex, newIndex) in anchors {
            let shift = words[newIndex].location - oldWords[oldIndex].location
            for (source, span) in wordSpans[oldIndex] {
                adjusted.append((source, span.with(range: NSRange(location: span.range.location + shift, length: span.range.length))))
            }
        }

        // Between anchors, the characters that survive carry their colours.
        var previous = (-1, -1)
        for anchor in anchors + [(before.count, after.count)] {
            let gapSpans = wordSpans[(previous.0 + 1)..<anchor.0].flatMap { $0 }
            let gapWords = words[(previous.1 + 1)..<anchor.1]
            if !gapSpans.isEmpty, !gapWords.isEmpty {
                let oldLower = previous.0 >= 0 ? NSMaxRange(oldWords[previous.0]) : start
                let oldUpper = anchor.0 < before.count ? oldWords[anchor.0].location : oldEnd
                let newLower = previous.1 >= 0 ? NSMaxRange(words[previous.1]) : start
                let newUpper = anchor.1 < after.count ? words[anchor.1].location : newEnd
                let surviving = survivingPieces(
                    gapSpans,
                    old: oldText, in: NSRange(location: oldLower, length: max(oldUpper - oldLower, 0)),
                    new: newText, in: NSRange(location: newLower, length: max(newUpper - newLower, 0))
                )
                for word in gapWords {
                    let held = surviving.pieces.compactMap { piece -> (source: Int, span: LyricsColorSpan)? in
                        let kept = NSIntersectionRange(piece.span.range, word)
                        return kept.length > 0 ? (piece.source, piece.span.with(range: kept)) : nil
                    }.sorted { $0.span.range.location < $1.span.range.location }
                    for (index, piece) in held.enumerated() {
                        guard surviving.aligned else {
                            adjusted.append(piece)
                            continue
                        }
                        // An aligned word is coloured gap-free by the spans it holds.
                        let lower = index == 0 ? word.location : piece.span.range.location
                        let upper = index + 1 < held.count ? held[index + 1].span.range.location : NSMaxRange(word)
                        adjusted.append((piece.source, piece.span.with(range: NSRange(location: lower, length: upper - lower))))
                    }
                }
            }
            previous = anchor
        }
        adjusted.sort { $0.span.range.location < $1.span.range.location }
        return clipped(adjusted)
    }

    /// The unchanged words of an edit, as (old index, new index) pairs: the
    /// most words matched by text in order, and among those, the ones that
    /// moved least, so a repeated word pairs with itself. Any alignment
    /// with E word edits stays within E of the diagonal, so the table is
    /// a band that widens until it holds the best alignment: the cost is
    /// (old + new words) x edits, not old x new, and never wider than
    /// `maximumEdits`. Nil past that: the edit is too large to align.
    static func anchoredWords(
        _ before: [String], at oldWords: [NSRange],
        _ after: [String], at newWords: [NSRange],
        maximumEdits: Int = 512
    ) -> [(Int, Int)]? {
        let n = before.count, m = after.count
        // The word counts alone need more edits than the limit: nothing is allocated.
        guard abs(n - m) <= maximumEdits else { return nil }
        guard n > 0, m > 0 else { return [] }
        let span = (oldWords.last.map(NSMaxRange) ?? 0) + (newWords.last.map(NSMaxRange) ?? 0) + 1
        let weight = span * (min(n, m) + 1)
        func moved(_ i: Int, _ j: Int) -> Int { abs(oldWords[i].location - newWords[j].location) }
        var band = min(max(abs(n - m), 8), maximumEdits)
        while true {
            let width = 2 * band + 1
            func cell(_ i: Int, _ j: Int) -> Int { i * width + (j - i + band) }
            var score = [Int](repeating: Int.min / 2, count: (n + 1) * width)
            func value(_ i: Int, _ j: Int) -> Int {
                if i == n || j == m { return 0 }
                return abs(j - i) <= band ? score[cell(i, j)] : Int.min / 2
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: min(m - 1, i + band), through: max(0, i - band), by: -1) {
                    var best = max(value(i + 1, j), value(i, j + 1))
                    if before[i] == after[j] { best = max(best, value(i + 1, j + 1) + weight - moved(i, j)) }
                    score[cell(i, j)] = best
                }
            }
            var anchors: [(Int, Int)] = []
            var i = 0, j = 0
            while i < n, j < m {
                if before[i] == after[j], value(i, j) == value(i + 1, j + 1) + weight - moved(i, j) {
                    anchors.append((i, j))
                    i += 1
                    j += 1
                } else if value(i, j) == value(i + 1, j) {
                    i += 1
                } else {
                    j += 1
                }
            }
            let edits = n + m - 2 * anchors.count
            if edits <= band { return anchors }
            if band >= maximumEdits { return nil }
            band = min(band * 2, maximumEdits)
        }
    }

    /// Where each span's characters in `oldRange` land in `newRange`, as
    /// runs. Aligned along the longest common run of characters when the
    /// gap is small enough (`aligned`); otherwise only the gap's common
    /// prefix and suffix survive, and nothing is stretched.
    private static func survivingPieces(
        _ spans: [(source: Int, span: LyricsColorSpan)],
        old: NSString, in oldRange: NSRange,
        new: NSString, in newRange: NSRange,
        aligns: Bool = true
    ) -> (pieces: [(source: Int, span: LyricsColorSpan)], aligned: Bool) {
        let oldUnits = (0..<oldRange.length).map { old.character(at: oldRange.location + $0) }
        let newUnits = (0..<newRange.length).map { new.character(at: newRange.location + $0) }
        var landing = [Int?](repeating: nil, count: oldUnits.count)
        let aligned = aligns && oldUnits.count * newUnits.count <= 250_000
        if aligned {
            // table[i * columns + j]: longest common run of oldUnits[i...] and newUnits[j...].
            let columns = newUnits.count + 1
            var table = [UInt16](repeating: 0, count: (oldUnits.count + 1) * columns)
            for i in stride(from: oldUnits.count - 1, through: 0, by: -1) {
                for j in stride(from: newUnits.count - 1, through: 0, by: -1) {
                    table[i * columns + j] = oldUnits[i] == newUnits[j]
                        ? table[(i + 1) * columns + j + 1] + 1
                        : max(table[(i + 1) * columns + j], table[i * columns + j + 1])
                }
            }
            var i = 0, j = 0
            while i < oldUnits.count, j < newUnits.count {
                if oldUnits[i] == newUnits[j] {
                    landing[i] = newRange.location + j
                    i += 1
                    j += 1
                } else if table[(i + 1) * columns + j] >= table[i * columns + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        } else {
            var prefix = 0
            while prefix < oldUnits.count, prefix < newUnits.count, oldUnits[prefix] == newUnits[prefix] {
                landing[prefix] = newRange.location + prefix
                prefix += 1
            }
            var suffix = 0
            while suffix < oldUnits.count - prefix, suffix < newUnits.count - prefix,
                  oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
                landing[oldUnits.count - 1 - suffix] = newRange.location + newUnits.count - 1 - suffix
                suffix += 1
            }
        }
        var pieces: [(source: Int, span: LyricsColorSpan)] = []
        for (source, span) in spans {
            let lower = max(span.range.location, oldRange.location) - oldRange.location
            let upper = min(NSMaxRange(span.range), NSMaxRange(oldRange)) - oldRange.location
            var run: NSRange?
            for index in lower..<max(lower, upper) {
                guard let target = landing[index] else { continue }
                if let current = run, NSMaxRange(current) == target {
                    run = NSRange(location: current.location, length: current.length + 1)
                } else {
                    if let current = run { pieces.append((source, span.with(range: current))) }
                    run = NSRange(location: target, length: 1)
                }
            }
            if let current = run { pieces.append((source, span.with(range: current))) }
        }
        return (pieces, aligned)
    }

    static func spansMoved(
        _ spans: [LyricsColorSpan],
        by range: NSRange,
        replacement: String
    ) -> (spans: [LyricsColorSpan], locations: [Int: Int]) {
        clipped(movedPieces(spans, by: range, replacement: replacement))
    }

    /// Each span's surviving pieces after one replacement, with the start it had before.
    private static func movedPieces(
        _ spans: [LyricsColorSpan],
        by range: NSRange,
        replacement: String
    ) -> [(source: Int, span: LyricsColorSpan)] {
        let editStart = range.location
        let editEnd = NSMaxRange(range)
        let replacementLength = replacement.utf16.count
        let delta = replacementLength - range.length
        let fullReplacement = NSRange(location: 0, length: replacementLength)
        let extendsWord = replacementLength > 0
            && LyricRegex.word.firstMatch(in: replacement, range: fullReplacement)?.range == fullReplacement
        // Each moved span remembers the start it had before the edit.
        var adjusted: [(source: Int, span: LyricsColorSpan)] = []
        adjusted.reserveCapacity(spans.count + 1)
        func keep(_ span: LyricsColorSpan, from start: Int, to end: Int) {
            guard end > start else { return }
            adjusted.append((span.range.location, LyricsColorSpan(
                range: NSRange(location: start, length: end - start),
                foreground: span.foreground,
                underline: span.underline
            )))
        }

        for span in spans {
            let start = span.range.location
            let end = NSMaxRange(span.range)
            if end < editStart || (end == editStart && !extendsWord) {
                keep(span, from: start, to: end)
            } else if start > editEnd || (start == editEnd && !extendsWord) {
                keep(span, from: start + delta, to: end + delta)
            } else if replacementLength > 0 && !extendsWord {
                // A space or punctuation inside a word splits it.
                keep(span, from: start, to: min(end, editStart))
                keep(span, from: editStart + replacementLength, to: end > editEnd ? end + delta : 0)
            } else {
                keep(
                    span,
                    from: start < editStart ? start : (extendsWord ? editStart : editStart + replacementLength),
                    to: end >= editEnd ? end + delta : (extendsWord ? editStart + replacementLength : editStart)
                )
            }
        }
        return adjusted
    }

    /// An edit joining two words can leave their spans touching; never
    /// overlapping. Identity follows the clipped start, so a line keeps its layer.
    private static func clipped(
        _ adjusted: [(source: Int, span: LyricsColorSpan)]
    ) -> (spans: [LyricsColorSpan], locations: [Int: Int]) {
        var previousEnd = 0
        var moved: [LyricsColorSpan] = []
        var locations: [Int: Int] = [:]
        for (source, span) in adjusted {
            let start = max(span.range.location, previousEnd)
            let end = NSMaxRange(span.range)
            guard end > start else { continue }
            previousEnd = end
            if locations[source] == nil { locations[source] = start }
            moved.append(LyricsColorSpan(
                range: NSRange(location: start, length: end - start),
                foreground: span.foreground,
                underline: span.underline
            ))
        }
        return (moved, locations)
    }

    /// `sectionLabelForeground` draws section header lines ("[Verse 1]",
    /// "[Chorus]") in a quieter neutral ink. It is a rendering attribute
    /// only: the stored text, its brackets, glyph metrics, selection and
    /// undo are untouched. Header lines carry no analysis spans, and spans
    /// are applied after it, so no lyric word loses its syllable or rhyme
    /// colour.
    ///
    /// Word colours are rendering attributes. The syllable underline is
    /// not: the text view draws only the foreground colour from rendering
    /// attributes, so `SyllableUnderlineView` draws it from `underlineSegments`.
    static func applyRenderingColors(
        _ spans: [LyricsColorSpan],
        text: String,
        storageLength: Int,
        layout: NSTextLayoutManager,
        foreground: PlatformColor,
        sectionLabelForeground: PlatformColor?
    ) {
        // Color attributes must not change glyph metrics or the user's selection.
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

    /// One line per laid-out fragment of each underlined span, where the
    /// font's own underline would sit, offset by the text container's
    /// `origin` in the text view. Only the frames are measured here; the
    /// spans are not re-analysed.
    static func underlineSegments(
        for spans: [LyricsColorSpan],
        layout: NSTextLayoutManager?,
        storage: NSTextStorage?,
        font defaultFont: PlatformFont,
        origin: CGPoint
    ) -> [SyllableUnderlineView.Segment] {
        guard spans.contains(where: { $0.underline != nil }),
              let layout, let storage,
              let content = layout.textContentManager else { return [] }
        let full = NSRange(location: 0, length: storage.length)
        layout.ensureLayout(for: content.documentRange)
        var segments: [SyllableUnderlineView.Segment] = []
        for span in spans {
            let range = NSIntersectionRange(span.range, full)
            guard range.length > 0, let underline = span.underline,
                  let lower = content.location(content.documentRange.location, offsetBy: range.location),
                  let upper = content.location(lower, offsetBy: range.length),
                  let textRange = NSTextRange(location: lower, end: upper) else { continue }
            let color = PlatformColor(underline)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont ?? defaultFont
            let thickness = max(CTFontGetUnderlineThickness(font as CTFont), 1)
            let belowBaseline = -CTFontGetUnderlinePosition(font as CTFont)
            var fragment = 0
            var lastFrame: CGRect?
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, baseline, _ in
                // The document's last line can report its segment twice.
                guard frame.width > 0, frame != lastFrame else { return true }
                lastFrame = frame
                segments.append(SyllableUnderlineView.Segment(
                    location: range.location,
                    fragment: fragment,
                    frame: CGRect(
                        x: frame.minX + origin.x,
                        y: frame.minY + baseline + belowBaseline - thickness / 2 + origin.y,
                        width: frame.width,
                        height: thickness
                    ),
                    color: color
                ))
                fragment += 1
                return true
            }
        }
        return segments
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

/// Draws the syllable underline over the editor's text area, one layer per
/// span fragment. When the spans change, a line keeps its left edge and its
/// position follows the text at once, while its width eases from the old
/// length to the new one on the feedback tier: each deleted character takes
/// its own width of line away and each typed letter adds one. A line whose
/// word is gone fades out on the same tier. Core Animation runs the motion,
/// so no analysis or layout happens per frame; Reduce Motion snaps.
/// On iOS it sits behind the text; on macOS (an NSTextView draws its text
/// in its own layer) it sits above it, where only the thin line shows.
final class SyllableUnderlineView: PlatformView {
    struct Segment: Equatable {
        let location: Int
        let fragment: Int
        let frame: CGRect
        let color: PlatformColor
    }

    private struct Key: Hashable {
        let location: Int
        let fragment: Int
    }

    static let duration = RhymeAITokens.Motion.feedbackDuration
    static let widthAnimationKey = "syllableUnderline.width"
    static let fadeAnimationKey = "syllableUnderline.fade"

    private(set) var segments: [Segment] = []
    private var lines: [Key: CALayer] = [:]

    #if canImport(UIKit)
    var motionEnabled: () -> Bool = { !UIAccessibility.isReduceMotionEnabled }
    private var hostLayer: CALayer { layer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    #else
    var motionEnabled: () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let hostLayer = CALayer()

    // Clicks and drags reach the text view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
        // Segment frames are in the text view's flipped (top-down) space.
        hostLayer.isGeometryFlipped = true
        hostLayer.anchorPoint = .zero
        layer?.addSublayer(hostLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.frame = bounds
        CATransaction.commit()
    }
    #endif

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The layer drawing a span's fragment, for tests.
    func line(at location: Int, fragment: Int = 0) -> CALayer? {
        lines[Key(location: location, fragment: fragment)]
    }

    /// `movedLocations` maps a previous span start to its start after an edit;
    /// a start missing from it lost its span. Without it, starts are kept.
    func update(_ newSegments: [Segment], movedLocations: [Int: Int]?, animated: Bool) {
        // The first lines on screen (a song opening, a guide turned on) appear at once.
        let animates = animated && motionEnabled() && !lines.isEmpty
        var previous: [Key: CALayer] = [:]
        var leaving: [CALayer] = []
        for (key, line) in lines {
            let location = movedLocations.map { $0[key.location] } ?? key.location
            if let location, previous[Key(location: location, fragment: key.fragment)] == nil {
                previous[Key(location: location, fragment: key.fragment)] = line
            } else {
                leaving.append(line)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var next: [Key: CALayer] = [:]
        for segment in newSegments {
            let key = Key(location: segment.location, fragment: segment.fragment)
            guard next[key] == nil else { continue }
            let line: CALayer
            let fromWidth: CGFloat
            if let existing = previous.removeValue(forKey: key) {
                line = existing
                fromWidth = (existing.presentation() ?? existing).bounds.width
            } else {
                line = CALayer()
                line.anchorPoint = CGPoint(x: 0, y: 0.5)
                hostLayer.addSublayer(line)
                fromWidth = 0
            }
            line.frame = segment.frame
            line.backgroundColor = segment.color.cgColor
            if animates, abs(fromWidth - segment.frame.width) > 0.5 {
                let width = CABasicAnimation(keyPath: "bounds.size.width")
                width.fromValue = fromWidth
                width.toValue = segment.frame.width
                width.duration = Self.duration
                width.timingFunction = CAMediaTimingFunction(name: .easeOut)
                line.add(width, forKey: Self.widthAnimationKey)
            } else {
                line.removeAnimation(forKey: Self.widthAnimationKey)
            }
            next[key] = line
        }
        leaving.append(contentsOf: previous.values)
        for line in leaving {
            guard animates else {
                line.removeFromSuperlayer()
                continue
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = (line.presentation() ?? line).opacity
            fade.toValue = Float(0)
            fade.duration = Self.duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            line.opacity = 0
            line.add(fade, forKey: Self.fadeAnimationKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak line] in
                line?.removeFromSuperlayer()
            }
        }
        CATransaction.commit()
        lines = next
        segments = newSegments
    }
}

private extension LyricsColorSpan {
    func with(range: NSRange) -> LyricsColorSpan {
        LyricsColorSpan(range: range, foreground: foreground, underline: underline)
    }
}
