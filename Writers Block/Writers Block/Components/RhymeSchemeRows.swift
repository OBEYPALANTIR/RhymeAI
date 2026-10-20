import Foundation

nonisolated struct RhymeSchemeRow {
    let line: String
    let letter: String?
    let isCurrent: Bool
}

nonisolated func rhymeSchemeRows(context: RhymeContext, scheme: String) -> [RhymeSchemeRow] {
    let letters = Array(scheme)
    guard !letters.isEmpty, !context.stanzaLines.isEmpty else { return [] }

    var lyricIndex = 0
    return context.stanzaLines.enumerated().map { rowIndex, line in
        let isCurrent = rowIndex == context.currentLineIndex
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let letter: String?
        if SectionMap.headerTitle(trimmed) != nil {
            // A section header starts a new stanza, so the scheme restarts under it.
            letter = nil
            lyricIndex = 0
        } else if trimmed.isEmpty {
            letter = isCurrent ? context.currentLetter : nil
        } else {
            letter = String(letters[lyricIndex % letters.count])
            lyricIndex += 1
        }
        return RhymeSchemeRow(line: line, letter: letter, isCurrent: isCurrent)
    }
}
