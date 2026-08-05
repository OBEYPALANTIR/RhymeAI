import Foundation

/// A single resolved section reference within the full lyrics.
struct SectionRef {
    let type: SongSection
    /// 1-based ordinal among sections of the same type (first Chorus = 1, second = 2, …).
    let ordinal: Int
    /// The human-readable label as it appears in the lyrics (e.g. "Verse 2", "Chorus").
    let label: String
    /// Line indices (0-based, inclusive start / exclusive end) within the full
    /// line array produced by splitting lyrics on "\n".
    let lineRange: Range<Int>
}

struct SectionInsertion {
    let text: String
    let cursor: Int
}

/// Parses the full lyrics string into an ordered list of sections, then lets
/// callers look up which section owns any given line index.
///
/// Recognised header formats (case-insensitive, trimmed):
///   • `[Verse 2]`, `[Chorus]`, `[Hook]`, `[Bridge]`  — bracketed
///   • `Verse 1`, `chorus`, `bridge`                   — bare line that is
///     ONLY a header word (optional number), nothing else
///
/// Lines before the first header become an implicit unknown section (ordinal 1).
nonisolated struct SectionMap {

    static let standardLabels = [
        "Intro",
        "Verse",
        "Pre-Chorus",
        "Chorus",
        "Hook",
        "Bridge",
        "Refrain",
        "Interlude",
        "Outro"
    ]

    let sections: [SectionRef]

    /// Build a map from the full lyrics string.
    init(lyrics: String) {
        let rawLines = lyrics.components(separatedBy: "\n")
        self.sections = Self.parse(rawLines: rawLines)
    }

    /// Section that owns `lineIndex`, or nil when the map is empty.
    func sectionAt(lineIndex: Int) -> SectionRef? {
        // Sections are in document order; walk backwards to find the nearest header.
        for section in sections.reversed() {
            if section.lineRange.lowerBound <= lineIndex {
                return section
            }
        }
        return sections.first
    }

    var allSections: [SectionRef] { sections }

    // MARK: - Lines for a specific section instance

    /// Non-header, non-empty lyric lines belonging to the first section of a
    /// given type. Returns nil when no such section exists.
    func lines(forFirstOf type: SongSection, in rawLines: [String]) -> [String]? {
        guard let first = sections.first(where: { $0.type == type }) else { return nil }
        let slice = rawLines[first.lineRange]
        let lyrics = slice.filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && Self.headerTitle(t) == nil
        }
        return lyrics.isEmpty ? nil : lyrics
    }

    // MARK: - Static parsing

    static func parse(rawLines: [String]) -> [SectionRef] {
        var results: [SectionRef] = []
        var ordinalsPerType: [SongSection: Int] = [:]

        // Collect (headerLineIndex, headerTitle?) pairs so we can compute ranges.
        var boundaries: [(lineIndex: Int, title: String?)] = [(0, nil)]
        for (idx, line) in rawLines.enumerated().dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title = headerTitle(trimmed), idx != 0 {
                boundaries.append((idx, title))
            }
        }
        // Also handle first line being a header.
        if let firstTitle = headerTitle(rawLines[0].trimmingCharacters(in: .whitespacesAndNewlines)) {
            boundaries[0] = (0, firstTitle)
        }

        for (pos, boundary) in boundaries.enumerated() {
            let startIdx = boundary.lineIndex
            let endIdx = pos + 1 < boundaries.count ? boundaries[pos + 1].lineIndex : rawLines.count
            let range = startIdx ..< endIdx

            let sectionType: SongSection
            let label: String
            let ordinal: Int
            if let title = boundary.title {
                sectionType = SongSection.fromHeader(title)
                label = title
                ordinalsPerType[sectionType, default: 0] += 1
                ordinal = ordinalsPerType[sectionType, default: 0]
            } else {
                // Implicit leading block before any header.
                sectionType = .unknown
                label = "Intro"
                ordinal = 1
            }

            results.append(SectionRef(type: sectionType, ordinal: ordinal, label: label, lineRange: range))
        }

        return results
    }

    /// Returns the header label when a trimmed line is a section header,
    /// otherwise nil. Handles both `[Verse 2]` and bare `Chorus` / `Verse 1`.
    static func headerTitle(_ trimmed: String) -> String? {
        // Bracketed form: [Verse 2], [Chorus], etc.
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        // Bare form: line must be ONLY a known keyword + optional number/ordinal.
        // Reject lines with extra content so "Verse is king" stays a lyric line.
        let barePattern = #"^(?:verse|chorus|hook|bridge|pre[\- ]?chorus|intro|outro|refrain|interlude)\s*(?:\d+)?$"#
        if trimmed.range(of: barePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed
        }
        return nil
    }

    static func lyricContent(_ lyrics: String) -> String {
        lyrics.components(separatedBy: "\n")
            .filter { headerTitle($0.trimmingCharacters(in: .whitespacesAndNewlines)) == nil }
            .joined(separator: "\n")
    }

    static func headerRanges(_ lyrics: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var lineStart = 0
        for line in lyrics.components(separatedBy: "\n") {
            let lineLength = line.utf16.count
            if lineLength > 0,
               headerTitle(line.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                ranges.append(NSRange(location: lineStart, length: lineLength))
            }
            lineStart += lineLength + 1
        }
        return ranges
    }

    static func insertHeader(_ label: String, in lyrics: String, cursor: Int) -> SectionInsertion {
        let nsLyrics = lyrics as NSString
        let safeCursor = min(max(cursor, 0), nsLyrics.length)
        let cleanLabel = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!cleanLabel.isEmpty, "Section label cannot be blank.")

        let before = nsLyrics.substring(to: safeCursor)
        let after = nsLyrics.substring(from: safeCursor)
        let leading: String
        if before.isEmpty || before.hasSuffix("\n\n") {
            leading = ""
        } else if before.hasSuffix("\n") {
            leading = "\n"
        } else {
            leading = "\n\n"
        }

        let trailing: String
        if after.isEmpty {
            trailing = "\n"
        } else if after.hasPrefix("\n\n") {
            trailing = ""
        } else if after.hasPrefix("\n") {
            trailing = "\n"
        } else {
            trailing = "\n\n"
        }

        let inserted = "\(leading)[\(cleanLabel)]\(trailing)"
        return SectionInsertion(
            text: before + inserted + after,
            cursor: safeCursor + inserted.utf16.count
        )
    }
}
