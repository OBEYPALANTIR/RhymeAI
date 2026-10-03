import Foundation

nonisolated enum SynonymPromptFormat: Equatable { case newlineList, jsonObject }
nonisolated enum SynonymValidationMode: Equatable { case syntaxOnly, knownWords }

protocol SynonymProviding {
    func getSynonyms(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        word: String,
        lineContext: String,
        excluding existing: [String],
        limit: Int
    ) async throws -> [String]
}

extension AIService: SynonymProviding {}

nonisolated struct SynonymGGUFRoute: Equatable {
    let filePath: String

    func generate(prompt: String, runner: LocalGGUFRunner) async throws -> String {
        try await runner.generate(prompt: prompt, loading: filePath)
    }
}

nonisolated struct SynonymLocalIdentity: Equatable {
    let engineChoice: GGUFEngineChoice
    let selectedFileName: String?
    let resolvedGGUFPath: String?
    let revision: Int

    var ggufRoute: SynonymGGUFRoute? {
        guard engineChoice == .gemma,
              GGUFModelService.isEngineAvailable,
              let resolvedGGUFPath else { return nil }
        return SynonymGGUFRoute(filePath: resolvedGGUFPath)
    }
}

enum SynonymSanitizer {
    static func extract(
        _ raw: String,
        excluding target: String,
        additionallyExcluding exclusions: [String] = [],
        limit: Int,
        validation: SynonymValidationMode = .syntaxOnly
    ) -> [String] {
        guard limit > 0 else { return [] }
        if validation == .knownWords, containsMarkupOrControl(raw) { return [] }
        let cleaned = extractCodeFencePayload(from: raw)
        guard !cleaned.isEmpty else { return [] }
        let candidates = parseCandidates(cleaned)
        let targetKey = canonicalKey(target)
        var seen = Set<String>()
        for exclusion in exclusions {
            seen.insert(canonicalKey(exclusion))
        }
        var result: [String] = []

        for rawCandidate in candidates {
            guard !rawCandidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                continue
            }
            let candidate = normalizeCandidate(rawCandidate)
            guard !candidate.isEmpty,
                  candidate.count <= 32,
                  candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !isPromptEchoLine(candidate),
                  isSingleWord(candidate),
                  validation != .knownWords || isKnownWord(candidate) else {
                continue
            }
            let key = canonicalKey(candidate)
            guard !key.isEmpty,
                  key != targetKey,
                  seen.insert(key).inserted else {
                continue
            }
            result.append(candidate)
            if result.count == limit { break }
        }
        return result
    }

    private static func extractCodeFencePayload(from raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("```"),
              let openingLineEnd = cleaned.firstIndex(of: "\n") else {
            return cleaned
        }
        let payloadStart = cleaned.index(after: openingLineEnd)
        guard let closingFence = cleaned.range(of: "```", range: payloadStart..<cleaned.endIndex) else {
            return String(cleaned[payloadStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(cleaned[payloadStart..<closingFence.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseCandidates(_ cleaned: String) -> [String] {
        if let data = cleaned.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) {
            if let object = value as? [String: Any] {
                guard let array = object["synonyms"] as? [Any] else { return [] }
                return array.compactMap { $0 as? String }
            }
            if let array = value as? [Any] {
                return array.compactMap { $0 as? String }
            }
        }
        return cleaned.components(separatedBy: .newlines).flatMap { line -> [String] in
            guard !isPromptEchoLine(line) else { return [] }
            return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
    }

    private static func normalizeCandidate(_ raw: String) -> String {
        var candidate = stripListPrefix(from: normalizePunctuation(raw))

        var removedWrapper = true
        while removedWrapper, candidate.count >= 2 {
            removedWrapper = false
            for pair in [("\"", "\""), ("'", "'"), ("(", ")"), ("[", "]"), ("`", "`")] {
                if candidate.hasPrefix(pair.0), candidate.hasSuffix(pair.1) {
                    candidate.removeFirst(pair.0.count)
                    candidate.removeLast(pair.1.count)
                    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    removedWrapper = true
                    break
                }
            }
            if candidate.hasPrefix("**"), candidate.hasSuffix("**"), candidate.count >= 4 {
                candidate.removeFirst(2)
                candidate.removeLast(2)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                removedWrapper = true
            }
        }
        return candidate
    }

    private static func stripListPrefix(from raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: #"^\s*(?:(?:[-*•])\s+|(?:\d+|[A-Za-z])\s*[.):]\s*)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePunctuation(_ raw: String) -> String {
        let normalized = raw.precomposedStringWithCompatibilityMapping
        return normalized.unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar.value {
            case 0x2018, 0x2019, 0x02BC, 0xFF07:
                result.append("'")
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212:
                result.append("-")
            case 0x201C, 0x201D:
                result.append("\"")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
    }

    private static func canonicalKey(_ raw: String) -> String {
        normalizePunctuation(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func isPromptEchoLine(_ raw: String) -> Bool {
        let normalizedLine = stripListPrefix(from: normalizePunctuation(raw))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contractTags = ["target", "context", "counts", "unique", "stop-early", "exclusions", "word"]
        if contractTags.contains(where: { tag in
            normalizedLine.contains("<\(tag)>")
                || normalizedLine.contains("<\(tag) ")
                || normalizedLine.contains("</\(tag)>")
        }) {
            return true
        }
        let line = normalizedLine.replacingOccurrences(of: "-", with: " ")
        let structuralKey = line.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        if structuralKey.contains("synonymcontract")
            || structuralKey.contains("followthestructuredcounts") {
            return true
        }
        let structuralKeys: Set<String> = [
            "startofturn", "startturn", "endofturn", "endturn", "assistantresponse", "modelresponse",
            "youarerhymeai", "returnonly", "ignoreinstructions"
        ]
        if structuralKeys.contains(structuralKey) { return true }
        let prefixes = [
            "start of turn", "end of turn", "assistant response", "model response",
            "task", "context", "rules", "do not", "already accepted",
            "you are rhymeai", "return only", "ignore instructions", "sure, here",
            "here are", "as an ai", "no json"
        ]
        return prefixes.contains { prefix in
            line == prefix
                || line.hasPrefix("\(prefix) ")
                || line.hasPrefix("\(prefix),")
                || line.hasPrefix("\(prefix):")
        }
    }

    private static func isSingleWord(_ candidate: String) -> Bool {
        var hasLetter = false
        var followsConnector = false
        for scalar in candidate.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                hasLetter = true
                followsConnector = false
            } else if CharacterSet.nonBaseCharacters.contains(scalar), hasLetter, !followsConnector {
                continue
            } else if scalar == "'" || scalar == "-" {
                guard hasLetter, !followsConnector else { return false }
                followsConnector = true
            } else {
                return false
            }
        }
        return hasLetter && !followsConnector
    }

    private static func isKnownWord(_ candidate: String) -> Bool {
        LexicalWordValidator.isKnownSpelling(candidate)
    }

    static func containsMarkupOrControl(_ raw: String) -> Bool {
        if raw.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar != "\n"
                && scalar != "\r"
                && scalar != "\t"
        }) {
            return true
        }
        if raw.contains("```") { return true }
        if raw.range(
            of: #"(?i)<\|turn>|<turn\|>|<?/?(?:start|end)_?(?:of_?)?turn>?\w*|_?response>|_?model_response>|assistant_response>|model_response>"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return raw.range(of: #"<\s*[/A-Za-z|]"#, options: .regularExpression) != nil
    }
}

enum SynonymGenerationPipeline {
    nonisolated static let minimumUsefulCount = 3

    static func collect(
        target: String,
        limit: Int,
        accepting existing: [String] = [],
        validation: SynonymValidationMode = .syntaxOnly,
        request: (_ exclusions: [String]) async throws -> String
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        let resultLimit = min(limit, 10)
        var accepted = SynonymSanitizer.extract(
            existing.joined(separator: "\n"),
            excluding: target,
            limit: resultLimit,
            validation: validation
        )
        let usefulCount = min(minimumUsefulCount, resultLimit)
        guard accepted.count < usefulCount else { return accepted }

        let firstRaw = try await request(accepted)
        try Task.checkCancellation()
        let first = SynonymSanitizer.extract(
            firstRaw,
            excluding: target,
            additionallyExcluding: accepted,
            limit: resultLimit - accepted.count,
            validation: validation
        )
        accepted.append(contentsOf: first)
        guard accepted.count < usefulCount else { return accepted }

        do {
            let topUpRaw = try await request(accepted)
            try Task.checkCancellation()
            let topUp = SynonymSanitizer.extract(
                topUpRaw,
                excluding: target,
                additionallyExcluding: accepted,
                limit: resultLimit - accepted.count,
                validation: validation
            )
            accepted.append(contentsOf: topUp)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if accepted.isEmpty { throw error }
        }
        try Task.checkCancellation()
        return accepted
    }
}
