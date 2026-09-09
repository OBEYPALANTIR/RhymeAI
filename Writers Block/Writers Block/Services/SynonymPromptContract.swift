import Foundation

nonisolated enum SynonymPromptContract {
    static func render(
        target rawTarget: String,
        context rawContext: String,
        limit: Int,
        exclusions rawExclusions: [String]
    ) -> String {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = String(trimmedContext.prefix(180))
        var seen = Set([canonicalKey(target)])
        var exclusions: [String] = []

        for rawExclusion in rawExclusions {
            let exclusion = rawExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = canonicalKey(exclusion)
            guard !exclusion.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            exclusions.append(exclusion)
        }

        let exclusionElements = exclusions
            .map { "<word>\(escapeXML($0))</word>" }
            .joined()

        return "<synonym-contract>"
            + "<target>\(escapeXML(target))</target>"
            + "<context>\(escapeXML(context))</context>"
            + "<counts minimum=\"3\" maximum=\"\(limit)\"></counts>"
            + "<unique required=\"true\"></unique>"
            + "<stop-early when-exhausted=\"true\"></stop-early>"
            + "<exclusions>\(exclusionElements)</exclusions>"
            + "</synonym-contract>"
    }

    private static func canonicalKey(_ value: String) -> String {
        value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
