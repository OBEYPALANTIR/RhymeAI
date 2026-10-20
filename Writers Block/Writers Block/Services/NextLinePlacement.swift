import Foundation

/// Where an accepted next-line suggestion goes, and what that position means for the
/// rhyme scheme. The rhyme context and the insertion both read this one value, so the
/// letter and anchor sent to the model always describe the line that gets inserted.
///
/// Placement rule (identical on Android, `NextLinePlacement.kt`):
/// - cursor on a blank line: the suggestion takes that line, and a blank line is kept after it;
/// - cursor anywhere on a non-blank line (lyric or header): the suggestion becomes a new
///   line directly after it. A lyric line is never split.
///
/// Scheme rule: a stanza starts after a blank line or a section header. The new line's
/// letter is `scheme[earlier lyric lines in the stanza % scheme length]`, and its anchor
/// is the latest earlier lyric line in the same stanza with that letter, if any.
nonisolated struct NextLinePlacement {
    /// Document lines, split on "\n".
    let lines: [String]
    /// Line the cursor is on.
    let cursorLineIndex: Int
    /// True when the cursor line is blank and the suggestion takes its place.
    let fillsBlankLine: Bool
    /// The blank-line-delimited block around the cursor, with one empty row at
    /// `rowIndex` standing for the line to be inserted.
    let stanzaRows: [String]
    let rowIndex: Int
    /// Trimmed lyric lines before the new line, back to the stanza start.
    let earlierLyricLines: [String]

    init(lyrics: String, cursorCharacterOffset: Int) {
        let lines = lyrics.components(separatedBy: "\n")
        let offset = min(max(cursorCharacterOffset, 0), lyrics.count)
        let cursorLine = String(lyrics.prefix(offset)).components(separatedBy: "\n").count - 1
        self.init(lines: lines, cursorLineIndex: cursorLine)
    }

    init(lines: [String], cursorLineIndex: Int) {
        let lines = lines.isEmpty ? [""] : lines
        let cursor = min(max(cursorLineIndex, 0), lines.count - 1)
        let isBlank: (Int) -> Bool = { Self.trimmed(lines[$0]).isEmpty }
        let blockStart = lines.indices.prefix(cursor).last(where: isBlank).map { $0 + 1 } ?? 0

        let rows: [String]
        let rowIndex: Int
        if isBlank(cursor) {
            rows = Array(lines[blockStart...cursor])
            rowIndex = cursor - blockStart
        } else {
            let blockEnd = lines.indices.dropFirst(cursor + 1).first(where: isBlank) ?? lines.endIndex
            rows = Array(lines[blockStart...cursor]) + [""] + Array(lines[(cursor + 1)..<blockEnd])
            rowIndex = cursor - blockStart + 1
        }

        var earlier: [String] = []
        for row in rows.prefix(rowIndex) {
            let line = Self.trimmed(row)
            if SectionMap.headerTitle(line) != nil {
                earlier.removeAll()
            } else if !line.isEmpty {
                earlier.append(line)
            }
        }

        self.lines = lines
        self.cursorLineIndex = cursor
        self.fillsBlankLine = isBlank(cursor)
        self.stanzaRows = rows
        self.rowIndex = rowIndex
        self.earlierLyricLines = earlier
    }

    /// Scheme letter of the line to be inserted. The scheme repeats in a longer stanza.
    func letter(scheme: [Character]) -> Character? {
        scheme.isEmpty ? nil : scheme[earlierLyricLines.count % scheme.count]
    }

    /// Latest earlier line in the stanza with the new line's letter; nil when the new
    /// line opens a rhyme sound.
    func anchorLine(scheme: [Character]) -> String? {
        guard let letter = letter(scheme: scheme) else { return nil }
        return earlierLyricLines.indices
            .last { scheme[$0 % scheme.count] == letter }
            .map { earlierLyricLines[$0] }
    }

    struct Insertion {
        let text: String
        /// UTF-16 range of the inserted suggestion.
        let insertedRange: NSRange
        /// UTF-16 cursor offset after the insertion.
        let cursor: Int
    }

    func inserting(_ suggestion: String) -> Insertion {
        var newLines = lines
        let suggestionIndex: Int
        let cursorOnFollowingLine: Bool
        if fillsBlankLine {
            suggestionIndex = cursorLineIndex
            newLines[cursorLineIndex] = suggestion
            newLines.insert("", at: cursorLineIndex + 1)
            cursorOnFollowingLine = true
        } else {
            suggestionIndex = cursorLineIndex + 1
            newLines.insert(suggestion, at: suggestionIndex)
            cursorOnFollowingLine = suggestionIndex == newLines.count - 1
            if cursorOnFollowingLine { newLines.append("") }
        }

        let location = newLines.prefix(suggestionIndex).reduce(0) { $0 + $1.utf16.count + 1 }
        let length = suggestion.utf16.count
        return Insertion(
            text: newLines.joined(separator: "\n"),
            insertedRange: NSRange(location: location, length: length),
            cursor: location + length + (cursorOnFollowingLine ? 1 : 0)
        )
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
