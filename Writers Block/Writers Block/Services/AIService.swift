import Foundation
import FoundationModels

enum AIServiceError: LocalizedError {
    case noApiKey(provider: String)
    case localModelUnavailable(reason: String)
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case networkUnavailable
    case requestTimedOut
    case blockedResponse
    case decodingError
    case noSafeSingleWordRhyme

    var errorDescription: String? {
        switch self {
        case .noApiKey(let provider):
            return "No API key set. Go to Settings to add your \(provider) API key."
        case .localModelUnavailable(let reason):
            return "On-device model unavailable: \(reason)"
        case .invalidResponse:
            return "Invalid response from server."
        case .apiError(let code, let msg):
            return "API error (\(code)): \(msg)"
        case .networkUnavailable:
            return "Provider request failed — check your connection and try again."
        case .requestTimedOut:
            return "Provider request timed out — try again in a moment."
        case .blockedResponse:
            return "Provider blocked the response for safety. Try adjusting the lyric or prompt."
        case .decodingError:
            return "Failed to parse AI response."
        case .noSafeSingleWordRhyme:
            return "No safe rhyme. Select the line."
        }
    }
}

struct AIService {

    // MARK: - Gemma/GGUF shared runner
    //
    // A single runner is shared process-wide so the model loads once and stays
    // resident. Actor isolation keeps all llama.cpp access on one domain.
    // When the llama.cpp SPM package is not resolved, makeLocalGGUFRunner()
    // returns GGUFModelStub — calls immediately throw localModelUnavailable.
    static let ggufRunner: LocalGGUFRunner = makeLocalGGUFRunner()

    // MARK: -

    struct SingleWordRewriteContext {
        let line: String
        let previousWord: String?
        let nextWord: String?
        let isLineEnding: Bool
    }

    private static let suggestionCount = 6
    private static let localRewriteAttempts = 2
    private static let fallbackRephraseWords: [String: [String]] = [
        "believe": ["imagine", "trust", "dream"],
        "birds": ["sparrows", "voices", "wings"],
        "calls": ["rings", "echoes", "signals"],
        "enemies": ["rivals", "foes", "strangers"],
        "feel": ["sense", "know", "ache"],
        "free": ["loose", "clear", "unbound"],
        "glow": ["gleam", "shine", "spark"],
        "lies": ["myths", "spin", "masks"],
        "real": ["true", "clear", "solid"],
        "street": ["block", "road", "lane"],
        "tvs": ["screens", "feeds", "channels"],
        "walls": ["barriers", "rooms", "blocks"]
    ]
    private static let fallbackHarderRhymeWords: [String: [String]] = [
        "believe": ["deceive", "relieve", "receive"],
        "birds": ["words", "herds", "thirds"],
        "calls": ["walls", "falls", "halls"],
        "enemies": ["remedies", "memories", "melodies"],
        "feel": ["real", "steel", "wheel"],
        "free": ["see", "be", "flee"],
        "glow": ["show", "flow", "low"],
        "lies": ["eyes", "skies", "disguise"],
        "real": ["feel", "steel", "wheel"],
        "street": ["beat", "heat", "feet"],
        "tvs": ["feeds", "screens", "dreams"],
        "walls": ["calls", "falls", "halls"]
    ]
    private static let fallbackPunchUpWords: [String: [String]] = [
        "believe": ["swallow", "worship", "chase"],
        "birds": ["sirens", "static", "wires"],
        "calls": ["alarms", "signals", "sirens"],
        "enemies": ["traitors", "targets", "rivals"],
        "feel": ["burn", "bleed", "know"],
        "free": ["wild", "untamed", "unbound"],
        "glow": ["flare", "blaze", "spark"],
        "lies": ["poison", "fraud", "venom"],
        "real": ["raw", "true", "solid"],
        "street": ["asphalt", "gutter", "curb"],
        "tvs": ["screens", "static", "feeds"],
        "walls": ["concrete", "barricades", "barriers"]
    ]

    func getSuggestions(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = .unknown,
        sectionOrdinal: Int = 1,
        firstChorusLines: [String]? = nil,
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) async throws -> [String] {
        if provider == .local {
            let localPrompt = buildLocalPrompt(
                theme: theme,
                lyrics: lyrics,
                targetRhymeLine: targetRhymeLine,
                rhymeType: rhymeType,
                currentLetter: currentLetter,
                currentSection: currentSection,
                sectionOrdinal: sectionOrdinal,
                firstChorusLines: firstChorusLines,
                useWholeSongContext: useWholeSongContext
            )
            let filter = RhymeLineFilter(targetLine: targetRhymeLine, rhymeType: rhymeType)

            // Gemma engine: route through downloaded GGUF model.
            if Self.shouldUseGemma() {
                let parsed = try await callGGUFSuggestions(prompt: localPrompt, limit: Self.suggestionCount)
                guard let filter else { return parsed }
                return filter.rank(parsed, want: Self.suggestionCount)
            }

            // Apple Intelligence fallback.
            if #available(iOS 26.0, *) {
                let parsed = try await callLocal(prompt: localPrompt, limit: Self.suggestionCount)
                guard let filter else { return parsed }
                return filter.rank(parsed, want: Self.suggestionCount)
            }
            throw AIServiceError.localModelUnavailable(reason: "Apple Intelligence local suggestions require iOS 26 or later.")
        }

        guard !apiKey.isEmpty else {
            throw AIServiceError.noApiKey(provider: provider.displayName)
        }

        let prompt = buildPrompt(
            theme: theme,
            lyrics: lyrics,
            targetRhymeLine: targetRhymeLine,
            rhymeType: rhymeType,
            rhymeScheme: rhymeScheme,
            currentLetter: currentLetter,
            currentSection: currentSection,
            sectionOrdinal: sectionOrdinal,
            firstChorusLines: firstChorusLines,
            complexity: complexity,
            useWholeSongContext: useWholeSongContext
        )

        let raw = try await callCloudText(
            provider: provider,
            apiKey: apiKey,
            modelId: modelId,
            prompt: prompt,
            kind: .suggestions
        )
        return parseSuggestionList(raw)
    }

    // MARK: - Streaming

    func streamSuggestions(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = .unknown,
        sectionOrdinal: Int = 1,
        firstChorusLines: [String]? = nil,
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if provider == .local {
                        let localPrompt = buildLocalPrompt(
                            theme: theme,
                            lyrics: lyrics,
                            targetRhymeLine: targetRhymeLine,
                            rhymeType: rhymeType,
                            currentLetter: currentLetter,
                            currentSection: currentSection,
                            sectionOrdinal: sectionOrdinal,
                            firstChorusLines: firstChorusLines,
                            useWholeSongContext: useWholeSongContext
                        )
                        let filter = RhymeLineFilter(
                            targetLine: targetRhymeLine,
                            rhymeType: rhymeType
                        )
                        if Self.shouldUseGemma() {
                            let excludedKeys = Set(
                                lyrics.components(separatedBy: .newlines)
                                    .map(normalizeSuggestionKey)
                                    .filter { !$0.isEmpty }
                            )
                            try await emitLines(
                                from: streamGGUFTokens(prompt: localPrompt),
                                into: continuation,
                                filter: filter,
                                excludedKeys: excludedKeys
                            )
                            continuation.finish()
                            return
                        }

                        let results = try await getSuggestions(
                            provider: provider,
                            apiKey: apiKey,
                            modelId: modelId,
                            theme: theme,
                            lyrics: lyrics,
                            targetRhymeLine: targetRhymeLine,
                            rhymeType: rhymeType,
                            rhymeScheme: rhymeScheme,
                            currentLetter: currentLetter,
                            currentSection: currentSection,
                            sectionOrdinal: sectionOrdinal,
                            firstChorusLines: firstChorusLines,
                            complexity: complexity,
                            useWholeSongContext: useWholeSongContext
                        )
                        for line in results { continuation.yield(line) }
                        continuation.finish()
                        return
                    }

                    guard !apiKey.isEmpty else {
                        throw AIServiceError.noApiKey(provider: provider.displayName)
                    }

                    let prompt = buildPrompt(
                        theme: theme,
                        lyrics: lyrics,
                        targetRhymeLine: targetRhymeLine,
                        rhymeType: rhymeType,
                        rhymeScheme: rhymeScheme,
                        currentLetter: currentLetter,
                        currentSection: currentSection,
                        sectionOrdinal: sectionOrdinal,
                        firstChorusLines: firstChorusLines,
                        complexity: complexity,
                        useWholeSongContext: useWholeSongContext
                    )

                    let tokens = streamCloudTokens(
                        provider: provider,
                        apiKey: apiKey,
                        modelId: modelId,
                        prompt: prompt
                    )

                    try await emitLines(
                        from: tokens,
                        into: continuation,
                        filter: RhymeLineFilter(targetLine: targetRhymeLine, rhymeType: rhymeType)
                    )
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: AIServiceError.requestTimedOut)
                } catch is URLError {
                    continuation.finish(throwing: AIServiceError.networkUnavailable)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func emitLines(
        from tokens: AsyncThrowingStream<String, Error>,
        into continuation: AsyncThrowingStream<String, Error>.Continuation,
        filter: RhymeLineFilter? = nil,
        excludedKeys: Set<String> = []
    ) async throws {
        var buffer = ""
        var seen = Set<String>()
        var emitted = 0
        var accepted = 0
        // Tier-0 lines wait here; they only ship if too few verified rhymes arrive.
        var held: [String] = []
        // With a filter the prompt over-generated 2x, so read past suggestionCount.
        let rawLimit = filter == nil ? Self.suggestionCount : Self.suggestionCount * 2

        streamLoop: for try await chunk in tokens {
            buffer += chunk
            while accepted < rawLimit, let newlineIdx = buffer.firstIndex(of: "\n") {
                let rawLine = String(buffer[..<newlineIdx])
                buffer = String(buffer[buffer.index(after: newlineIdx)...])
                guard let cleaned = cleanSuggestionLine(rawLine) else { continue }
                let key = normalizeSuggestionKey(cleaned)
                guard !key.isEmpty,
                      !excludedKeys.contains(key),
                      seen.insert(key).inserted else {
                    continue
                }
                accepted += 1
                if let filter, filter.tier(of: cleaned) == 0 {
                    held.append(cleaned)
                } else {
                    continuation.yield(cleaned)
                    emitted += 1
                }
                if emitted >= Self.suggestionCount { break streamLoop }
            }
            if accepted >= rawLimit { break }
        }

        if emitted < Self.suggestionCount, accepted < rawLimit {
            let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty, let cleaned = cleanSuggestionLine(remaining) {
                let key = normalizeSuggestionKey(cleaned)
                if !key.isEmpty,
                   !excludedKeys.contains(key),
                   seen.insert(key).inserted {
                    if let filter, filter.tier(of: cleaned) == 0 {
                        held.append(cleaned)
                    } else {
                        continuation.yield(cleaned)
                        emitted += 1
                    }
                }
            }
        }

        // Stream is done; top up with the best of the non-rhyming leftovers.
        if let filter, emitted < Self.suggestionCount {
            for line in filter.rank(held, want: Self.suggestionCount - emitted) {
                continuation.yield(line)
                emitted += 1
            }
        }
    }

    private func streamCloudTokens(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        prompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeProviderRequest(
                        provider: provider,
                        apiKey: apiKey,
                        modelId: modelId,
                        prompt: prompt,
                        kind: .stream
                    )
                    let payloads = httpPostStream(
                        url: request.url,
                        headers: request.headers,
                        body: request.body
                    )
                    for try await payload in payloads {
                        if let text = Self.streamText(provider: provider, payload: payload) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func httpPostStream(
        url: URL,
        headers: [String: String],
        body: Data
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.timeoutInterval = 60
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIServiceError.invalidResponse
                    }
                    if !(200...299).contains(httpResponse.statusCode) {
                        // Drain the response so the connection cleans up, but do not
                        // surface the body — provider error payloads can echo back
                        // the request URL or the API key into user-visible text.
                        // A drain failure must not mask the mapped status message.
                        do { for try await _ in bytes {} } catch {}
                        throw AIServiceError.apiError(
                            statusCode: httpResponse.statusCode,
                            message: AIService.userFacingStatusMessage(for: httpResponse.statusCode)
                        )
                    }
                    for try await line in bytes.lines {
                        if line.isEmpty || line.hasPrefix(":") { continue }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func cleanSuggestionLine(_ line: String) -> String? {
        var cleaned = stripLocalModelArtifacts(line)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        let markerOnly = #"^(?:_?response>|_?model_response>|assistant_response>|model_response>|<?/?(?:start|end)_?(?:of_?)?turn>?\w*|<[^>]+>|user|model|assistant)\s*$"#
        if cleaned.range(of: markerOnly, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        let markerPrefix = #"^(?:_?response>|_?model_response>|assistant_response>|model_response>|assistant:|model:|user:|<?/?(?:start|end)_?(?:of_?)?turn>?\w*)\s*"#
        if let range = cleaned.range(of: markerPrefix, options: [.regularExpression, .caseInsensitive]) {
            cleaned = String(cleaned[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = cleaned.range(of: #"^(?:[-*]\s+|\d+[.)]\s*)"#, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")), cleaned.count > 1 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptEcho = #"^(?:task:|theme:|rhyme scheme:|lyrics context:|rules:|return exactly|one suggestion|no numbering|keep each|you are rhymeai)"#
        if cleaned.range(of: promptEcho, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        if containsLocalControlMarker(cleaned) {
            return nil
        }
        if cleaned.isEmpty || cleaned.count > 140 { return nil }
        return cleaned
    }

    private func normalizeSuggestionKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    // MARK: - Prompt Builder

    private static func explicitSectionLabelForSection(
        in lyrics: String,
        section: SongSection,
        ordinal: Int
    ) -> String? {
        let rawLines = lyrics.components(separatedBy: "\n")
        guard let ref = SectionMap(lyrics: lyrics).sections.first(where: {
            $0.type == section && $0.ordinal == ordinal
        }),
        rawLines.indices.contains(ref.lineRange.lowerBound) else {
            return nil
        }
        return SectionMap.headerTitle(
            rawLines[ref.lineRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func explicitSectionLabelAtOffset(
        in lyrics: String,
        characterOffset: Int?
    ) -> String? {
        guard let characterOffset else { return nil }
        let safeOffset = min(max(characterOffset, 0), lyrics.count)
        let lineIndex = lyrics.prefix(safeOffset).reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        let rawLines = lyrics.components(separatedBy: "\n")
        guard let ref = SectionMap(lyrics: lyrics).sectionAt(lineIndex: lineIndex),
              rawLines.indices.contains(ref.lineRange.lowerBound) else {
            return nil
        }
        return SectionMap.headerTitle(
            rawLines[ref.lineRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func sectionLabelDirective(_ label: String?) -> String? {
        guard let label else { return nil }
        let safeLabel = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "'")
        guard !safeLabel.isEmpty else { return nil }

        let squashed = safeLabel.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        let role: String
        if squashed.contains("prechorus") {
            role = "Build momentum and tension toward the chorus without resolving the hook early."
        } else if squashed.hasPrefix("intro") {
            role = "Establish the song's mood, world, or central image while leaving room for the song to open up."
        } else if squashed.hasPrefix("hook") {
            role = "Center the shortest, most memorable, repeatable phrase in the song."
        } else if squashed.hasPrefix("refrain") {
            role = "Craft a returning line or compact phrase that can recur without becoming a full chorus."
        } else if squashed.hasPrefix("interlude") {
            role = "Use this as a sparse transition; keep any lyric minimal and textural."
        } else if squashed.hasPrefix("outro") {
            role = "Resolve or echo the song's core idea and create a clear sense of closure."
        } else {
            role = "Follow the named section's structural role when shaping the next line."
        }
        return """
        Current section label: "\(safeLabel)". Treat this label as song structure, not lyric content.
        Section-specific direction: \(role)
        """
    }

    func buildPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = .unknown,
        sectionOrdinal: Int = 1,
        firstChorusLines: [String]? = nil,
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) -> String {
        let effectiveTheme = useWholeSongContext
            ? "Whole song context enabled; infer the theme from the full lyrics."
            : (theme.isEmpty ? "No specific theme provided" : theme)

        let constraintBlock = Self.rhymeConstraintBlock(
            targetRhymeLine: targetRhymeLine,
            rhymeType: rhymeType,
            currentSection: currentSection,
            firstChorusEndWords: firstChorusLines.map { Self.endWords(of: $0) }
        )
        // Over-generate 2x when ending words are constrained so the rhyme
        // filter can discard misses and still deliver a full set.
        let requestCount = constraintBlock == nil ? Self.suggestionCount : Self.suggestionCount * 2

        var rhymeInstruction: String
        if let target = targetRhymeLine {
            rhymeInstruction = """
            Crucially, the new line MUST end with a **\(rhymeType.displayName)** to this specific line: "\(target)".
            """
        } else {
            rhymeInstruction = """
            Since this is a new rhyme sound ("\(currentLetter)"), the new line should introduce a new end-rhyme that fits the meter and theme.
            """
        }
        if let constraintBlock {
            rhymeInstruction += "\n" + constraintBlock
        }

        // Verbatim section-instance sentences for parity with Android.
        let sectionInstanceHint = Self.sectionInstanceSentence(
            section: currentSection,
            ordinal: sectionOrdinal,
            firstChorusLines: firstChorusLines
        )
        let sectionLabelHint = Self.sectionLabelDirective(
            Self.explicitSectionLabelForSection(
                in: lyrics,
                section: currentSection,
                ordinal: sectionOrdinal
            )
        )

        let rhymeAdherence = targetRhymeLine != nil
            ? ", and strictly adhere to the requested rhyme type (\(rhymeType.displayName))"
            : ""
        let songContextInstruction = useWholeSongContext
            ? "Analyze the whole song for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary. Make each suggestion feel connected to the entire song while still fitting the immediate target line and rhyme scheme."
            : "Prioritize the immediate writing context, current stanza, target line, rhyme scheme, and provided theme/context."

        var prompt = """
        You are an expert songwriter and lyricist.
        The user is writing a song with the following theme/context: "\(effectiveTheme)".
        Here are the current lyrics:
        \"""
        \(lyrics)
        \"""

        The user needs a line that follows the current lyrics.
        The current stanza follows a "\(rhymeScheme)" rhyme scheme, and the next line corresponds to the letter "\(currentLetter)".
        Current song section: \(currentSection.displayName).
        \(currentSection.promptHint)
        """
        if let sectionLabelHint {
            prompt += "\n" + sectionLabelHint
        }
        if let sectionInstanceHint, !sectionInstanceHint.isEmpty {
            prompt += "\n" + sectionInstanceHint
        }
        prompt += """

        \(rhymeInstruction)
        \(songContextInstruction)

        Complexity level: \(complexity.label). \(complexity.promptHint)

        Provide \(requestCount) creative, poetic, and contextually relevant suggestions for the next line.
        Make sure the rhythm and meter match the style of the current lyrics\(rhymeAdherence).

        Respond with exactly \(requestCount) lines, one suggestion per line. No numbering, no bullets, no quotes, no markdown, no code fences, and no commentary — just the bare suggestion lines.
        """
        return prompt
    }

    /// Constraint block shared by the cloud and local prompts. Returns nil
    /// when there is no target line or the dictionary can't offer ending
    /// words — then prompts and counts must stay exactly as before.
    ///
    /// When `firstChorusEndWords` is non-nil the candidates are prepended with
    /// those words (chorus repeat) or have them removed (verse/bridge exclusion).
    static func rhymeConstraintBlock(
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        currentSection: SongSection = .unknown,
        firstChorusEndWords: [String]? = nil
    ) -> String? {
        guard let target = targetRhymeLine,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let targetWord = RhymeConstraint.lineEndWord(target)
        guard !targetWord.isEmpty else { return nil }
        var candidates = RhymeConstraint.candidateEndWords(targetWord: targetWord, rhymeType: rhymeType)
        guard !candidates.isEmpty else { return nil }

        // Chorus 2nd+: prepend first-chorus end words so they rank highest.
        // Verse/Bridge: exclude first-chorus end words to diversify rhyme sounds.
        if let chorusWords = firstChorusEndWords, !chorusWords.isEmpty {
            switch currentSection {
            case .chorus:
                // Inject hook end-words at the front; remove any duplicates from the tail.
                let hookSet = Set(chorusWords)
                candidates = chorusWords + candidates.filter { !hookSet.contains($0) }
            case .verse, .bridge:
                // Strip chorus end-words unless doing so would empty the list.
                let filtered = candidates.filter { !chorusWords.contains($0) }
                if !filtered.isEmpty { candidates = filtered }
            case .unknown:
                break
            }
        }

        return """
        The new line must rhyme with: "\(target)" (it ends with "\(targetWord)").
        End each line with one of these rhyming words: \(candidates.joined(separator: ", ")) (choose the most natural fit).
        """
    }

    /// Verbatim section-instance sentence inserted after the section hint.
    /// Matches the Android implementation exactly.
    static func sectionInstanceSentence(
        section: SongSection,
        ordinal: Int,
        firstChorusLines: [String]?
    ) -> String? {
        switch section {
        case .chorus:
            guard ordinal >= 2, let lines = firstChorusLines, !lines.isEmpty else { return nil }
            let joined = lines.joined(separator: "\n")
            return "This is the chorus (instance \(ordinal)). Keep hook language and ending words consistent with the established chorus:\n\(joined)"
        case .verse:
            return "This is Verse \(ordinal)."
        case .bridge:
            return "This is the bridge — introduce a contrasting rhyme sound and cadence; avoid the chorus's ending words."
        case .unknown:
            return nil
        }
    }

    /// Last word of each line, normalized — used to derive end-word sets from
    /// a block of chorus lines for constraint building.
    static func endWords(of lines: [String]) -> [String] {
        lines.compactMap { line -> String? in
            let w = RhymeConstraint.lineEndWord(line)
            return w.isEmpty ? nil : w
        }
    }

    // MARK: - Cloud providers

    private enum ProviderRequestKind {
        case suggestions
        case rawJSON
        case stream

        var isStreaming: Bool {
            if case .stream = self { return true }
            return false
        }

        var requestsJSON: Bool {
            if case .rawJSON = self { return true }
            return false
        }
    }

    private struct ProviderHTTPRequest {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private func callCloudText(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        prompt: String,
        kind: ProviderRequestKind
    ) async throws -> String {
        let request = try makeProviderRequest(
            provider: provider,
            apiKey: apiKey,
            modelId: modelId,
            prompt: prompt,
            kind: kind
        )
        let data = try await httpPost(url: request.url, headers: request.headers, body: request.body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.decodingError
        }
        return try Self.responseText(provider: provider, from: json)
    }

    private func makeProviderRequest(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        prompt: String,
        kind: ProviderRequestKind
    ) throws -> ProviderHTTPRequest {
        switch provider {
        case .gemini:
            return try makeGeminiRequest(apiKey: apiKey, modelId: modelId, prompt: prompt, kind: kind)
        case .openai:
            return try makeOpenAIRequest(apiKey: apiKey, modelId: modelId, prompt: prompt, kind: kind)
        case .claude:
            return try makeClaudeRequest(apiKey: apiKey, modelId: modelId, prompt: prompt, kind: kind)
        case .local:
            throw AIServiceError.invalidResponse
        }
    }

    private func makeGeminiRequest(
        apiKey: String,
        modelId: String,
        prompt: String,
        kind: ProviderRequestKind
    ) throws -> ProviderHTTPRequest {
        let url = try Self.geminiURL(
            modelId: modelId,
            method: kind.isStreaming ? "streamGenerateContent" : "generateContent",
            query: kind.isStreaming ? "alt=sse" : nil
        )
        var body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]]
        ]
        if kind.requestsJSON {
            body["generationConfig"] = ["responseMimeType": "application/json"]
        }
        return ProviderHTTPRequest(
            url: url,
            headers: [
                "Content-Type": "application/json",
                "x-goog-api-key": apiKey
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    private func makeOpenAIRequest(
        apiKey: String,
        modelId: String,
        prompt: String,
        kind: ProviderRequestKind
    ) throws -> ProviderHTTPRequest {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIServiceError.invalidResponse
        }
        var body: [String: Any] = [
            "model": modelId,
            "messages": [["role": "user", "content": prompt]]
        ]
        if kind.isStreaming {
            body["stream"] = true
            body["temperature"] = 0.8
        } else if kind.requestsJSON {
            body["response_format"] = ["type": "json_object"]
        }
        var headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)"
        ]
        if kind.isStreaming {
            headers["Accept"] = "text/event-stream"
        }
        return ProviderHTTPRequest(
            url: url,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    private func makeClaudeRequest(
        apiKey: String,
        modelId: String,
        prompt: String,
        kind: ProviderRequestKind
    ) throws -> ProviderHTTPRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIServiceError.invalidResponse
        }
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]]
        ]
        if kind.isStreaming {
            body["stream"] = true
        }
        var headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01"
        ]
        if kind.isStreaming {
            headers["Accept"] = "text/event-stream"
        }
        return ProviderHTTPRequest(
            url: url,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    private static func responseText(provider: AIProvider, from json: [String: Any]) throws -> String {
        switch provider {
        case .gemini:
            return try geminiText(from: json)
        case .openai:
            return try openAIText(from: json)
        case .claude:
            return try claudeText(from: json)
        case .local:
            throw AIServiceError.invalidResponse
        }
    }

    private static func openAIText(from json: [String: Any]) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIServiceError.decodingError
        }
        return content
    }

    private static func claudeText(from json: [String: Any]) throws -> String {
        guard let contentArray = json["content"] as? [[String: Any]],
              let text = contentArray.first?["text"] as? String else {
            throw AIServiceError.decodingError
        }
        return text
    }

    private static func streamText(provider: AIProvider, payload: String) -> String? {
        guard let chunk = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return nil
        }
        switch provider {
        case .gemini:
            guard let candidates = chunk["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else {
                return nil
            }
            return text
        case .openai:
            guard let choices = chunk["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                return nil
            }
            return content
        case .claude:
            guard chunk["type"] as? String == "content_block_delta",
                  let delta = chunk["delta"] as? [String: Any],
                  let text = delta["text"] as? String else {
                return nil
            }
            return text
        case .local:
            return nil
        }
    }

    // MARK: - Local

    private func buildLocalPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        currentLetter: String,
        currentSection: SongSection = .unknown,
        sectionOrdinal: Int = 1,
        firstChorusLines: [String]? = nil,
        useWholeSongContext: Bool
    ) -> String {
        let constraintBlock = Self.rhymeConstraintBlock(
            targetRhymeLine: targetRhymeLine,
            rhymeType: rhymeType,
            currentSection: currentSection,
            firstChorusEndWords: firstChorusLines.map { Self.endWords(of: $0) }
        )
        // Over-generate 2x when ending words are constrained so the rhyme
        // filter can discard misses and still deliver a full set.
        // Cloud over-generates 2x for the rhyme filter; the on-device model is
        // slow and small, and doubling its output length doubles the chance of
        // malformed output — keep the ask at 6 and let the filter re-rank.
        let requestCount = Self.suggestionCount

        var rhymeHint: String
        if let targetRhymeLine {
            rhymeHint = "Each line must rhyme (\(rhymeType.displayName)) with: \"\(targetRhymeLine)\""
        } else {
            rhymeHint = "Start a new rhyme sound for letter \"\(currentLetter)\"."
        }
        if let constraintBlock {
            rhymeHint += "\n" + constraintBlock
        }

        let sectionInstanceHint = Self.sectionInstanceSentence(
            section: currentSection,
            ordinal: sectionOrdinal,
            firstChorusLines: firstChorusLines
        )
        let sectionLabelHint = Self.sectionLabelDirective(
            Self.explicitSectionLabelForSection(
                in: lyrics,
                section: currentSection,
                ordinal: sectionOrdinal
            )
        )

        let songContextInstruction = useWholeSongContext
            ? "Use the full song for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary."
            : "Use the immediate stanza, rhyme target, and theme first."
        let themeClause = !useWholeSongContext && !theme.isEmpty ? " about \(theme)" : ""

        var prompt = """
        Write \(requestCount) next lines for this song\(themeClause).
        Current song section: \(currentSection.displayName).
        \(currentSection.promptHint)
        """
        if let sectionLabelHint {
            prompt += "\n" + sectionLabelHint
        }
        if let sectionInstanceHint, !sectionInstanceHint.isEmpty {
            prompt += "\n" + sectionInstanceHint
        }
        prompt += """

        \(rhymeHint)
        \(songContextInstruction)

        Lyrics so far:
        \(lyrics)

        Reply with exactly \(requestCount) lines, one per line, no numbering, no extra text.
        """
        return prompt
    }

    @available(iOS 26.0, *)
    private func callLocal(prompt: String, limit: Int) async throws -> [String] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIServiceError.localModelUnavailable(reason: describe(model.availability))
        }

        let session = LanguageModelSession(
            model: model,
            instructions: "You are an expert songwriter and lyricist. Return concise lyric line suggestions only."
        )
        let response = try await session.respond(to: prompt, options: Self.localGenerationOptions(maxTokens: 256))
        let parsed = parseSuggestionList(response.content, limit: limit)
        guard !parsed.isEmpty else {
            throw AIServiceError.decodingError
        }
        return parsed
    }

    @available(iOS 26.0, *)
    private func describe(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "ready"
        case .unavailable(.deviceNotEligible):
            return "this device is not eligible for Apple Intelligence local models."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled."
        case .unavailable(.modelNotReady):
            return "the local model is still downloading or not ready yet."
        @unknown default:
            return "unknown availability state."
        }
    }

    // MARK: - GGUF / Gemma routing helpers

    /// Returns true when calls should be routed through the Gemma GGUF runner.
    /// Conditions: llama.cpp engine is compiled in, engine choice is .gemma,
    /// and at least one GGUF file exists in the models directory.
    static func shouldUseGemma() -> Bool {
        guard GGUFModelService.isEngineAvailable else { return false }
        guard GGUFEngineChoice.current == .gemma else { return false }
        return firstGGUFPath() != nil
    }

    /// Returns the path to the first available GGUF model file, or nil.
    static func firstGGUFPath() -> String? {
        let installed = GGUFModelStorage.installedModelFileNames()
        guard let fileName = GGUFModelSelection.preferredFileName(in: installed),
              let directory = try? GGUFModelStorage.modelsDirectory(create: false) else {
            return nil
        }
        return directory.appendingPathComponent(fileName).path
    }

    /// Ensure the shared GGUF runner has the correct model loaded, then call
    /// generate(prompt:) and return the raw output.
    private func callGGUF(prompt: String) async throws -> String {
        let runner = Self.ggufRunner
        let path: String
        // Check if loaded path matches available file.
        if let p = Self.firstGGUFPath() {
            path = p
        } else {
            throw AIServiceError.localModelUnavailable(
                reason: "No GGUF model found. Download a Gemma model in Settings."
            )
        }

        try await LocalInferenceStatus.shared.load(runner, path: path)

        return try await runner.generate(prompt: prompt)
    }

    private func streamGGUFTokens(
        prompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let path = Self.firstGGUFPath() else {
                        throw AIServiceError.localModelUnavailable(
                            reason: "No GGUF model found. Download a Gemma model in Settings."
                        )
                    }
                    let runner = Self.ggufRunner
                    try await LocalInferenceStatus.shared.load(runner, path: path)
                    _ = try await runner.generate(prompt: prompt) { token in
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Route a suggestion prompt through Gemma and parse the result.
    private func callGGUFSuggestions(prompt: String, limit: Int) async throws -> [String] {
        let raw = try await callGGUF(prompt: prompt)
        let parsed = parseSuggestionList(raw, limit: limit)
        guard !parsed.isEmpty else {
            throw AIServiceError.decodingError
        }
        return parsed
    }

    /// Route a rewrite prompt through Gemma and clean the result.
    /// For passage rewrites uses cleanLocalRewrite; for single-word uses the
    /// same accept/fallback pipeline as Apple Intelligence.
    private func callGGUFRewrite(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection,
        selectionStart: Int?,
        rejectedCandidates: Set<String>
    ) async throws -> String {
        // Build the same local prompt used for Apple Intelligence — Gemma
        // understands it, and the output is cleaned the same way.
        // IMPORTANT: Gemma must use the raw action.instruction for punchUp —
        // do NOT soften it (no localRewriteInstruction(for:)); Apple's guardrails
        // don't apply here.
        let prompt = buildGemmaRewritePrompt(
            action: action,
            lyrics: lyrics,
            selection: selection,
            currentSection: currentSection,
            selectionStart: selectionStart,
            rejectedCandidates: rejectedCandidates
        )

        let singleWord = isSingleWordSelection(selection)
        let raw = try await callGGUF(prompt: prompt)
        let parsed = cleanLocalRewrite(raw, selection: selection)

        if !singleWord {
            guard !parsed.isEmpty else { throw AIServiceError.decodingError }
            return parsed
        }

        // Single-word path: accept/fallback pipeline (same shape as Apple Intelligence).
        let context = singleWordRewriteContext(lyrics: lyrics, selection: selection, selectionStart: selectionStart)
        let rejectKeys = rewriteRejectKeys(selection: selection, rejectedCandidates: rejectedCandidates)
        let accepted = acceptLocalSingleWordRewrite(
            candidate: parsed,
            selection: selection,
            action: action,
            context: context,
            rejectedCandidates: rejectKeys
        )
        if !accepted.isEmpty { return accepted }

        let fallback = fallbackLocalSingleWordRewrite(
            selection: selection,
            action: action,
            context: context,
            rejectedCandidates: rejectKeys
        )
        if !fallback.isEmpty { return fallback }

        if action == .harderRhyme { throw AIServiceError.noSafeSingleWordRhyme }
        throw AIServiceError.decodingError
    }

    /// Builds the rewrite prompt for Gemma. Same structure as buildLocalRewritePrompt
    /// but uses the raw action.instruction (no softening) for punchUp.
    private func buildGemmaRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = .unknown,
        selectionStart: Int? = nil,
        rejectedCandidates: Set<String> = []
    ) -> String {
        let sectionLabelHint = Self.sectionLabelDirective(
            Self.explicitSectionLabelAtOffset(
                in: lyrics,
                characterOffset: selectionStart
            )
        ) ?? ""
        let singleWord = isSingleWordSelection(selection)
        let selectedLine = selectionStart.flatMap { lyricLine(at: $0, in: lyrics) }
        let rejectedKeys = rewriteRejectKeys(selection: selection, rejectedCandidates: rejectedCandidates)
        let rejectedRule = singleWord && !rejectedKeys.isEmpty
            ? "Do not return any of these rejected words: \(rejectedKeys.sorted().joined(separator: ", "))."
            : ""
        let taskLine = singleWord
            ? "Replace the selected word with a different word that fits the song."
            : "Rewrite the selected passage from this song."
        let outputRules = singleWord
            ? """
            Return exactly one replacement word.
            The replacement must be different from the selected word.
            Do not return "\(selection)".
            \(rejectedRule)
            No quotes, no labels, no commentary.
            """
            : """
            Reply with the rewritten passage only.
            Preserve line breaks if the selection has multiple lines.
            No quotes, no labels, no commentary.
            """
        // Gemma: use full action.instruction — no guardrail softening needed.
        return """
        \(taskLine)
        Current song section: \(currentSection.displayName).
        \(currentSection.promptHint)
        \(sectionLabelHint)
        Action: \(action.label).
        Instruction: \(action.instruction)

        Lyrics so far:
        \(lyrics)

        \(selectedLine.map { "Line containing the selected word:\n\($0)\n" } ?? "")
        Selected passage:
        \(selection)

        Rules:
        \(outputRules)
        """
    }

    // MARK: - Test access shims

    /// Exposed for unit tests that verify Gemma rewrite prompt construction.
    func buildGemmaRewritePromptForTest(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection,
        selectionStart: Int?,
        rejectedCandidates: Set<String>
    ) -> String {
        buildGemmaRewritePrompt(
            action: action,
            lyrics: lyrics,
            selection: selection,
            currentSection: currentSection,
            selectionStart: selectionStart,
            rejectedCandidates: rejectedCandidates
        )
    }

    // MARK: - Synonyms

    func getSynonyms(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        word: String,
        lineContext: String,
        limit: Int = 8
    ) async throws -> [String] {
        let target = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }

        let prompt = buildSynonymsPrompt(word: target, lineContext: lineContext, limit: limit)

        if provider == .local {
            let raw: String

            // Gemma engine: route through downloaded GGUF model.
            if Self.shouldUseGemma() {
                raw = try await callGGUF(prompt: prompt)
            } else if #available(iOS 26.0, *) {
                // Apple Intelligence fallback.
                raw = try await callLocalRaw(prompt: prompt, instructions: "You are an expert lexicographer. Reply ONLY with the requested JSON object.")
            } else {
                throw AIServiceError.localModelUnavailable(reason: "Apple Intelligence synonyms require iOS 26 or later.")
            }
            return extractSynonyms(raw, exclude: target, limit: limit)
        }

        guard !apiKey.isEmpty else {
            throw AIServiceError.noApiKey(provider: provider.displayName)
        }

        let raw = try await callCloudText(
            provider: provider,
            apiKey: apiKey,
            modelId: modelId,
            prompt: prompt,
            kind: .rawJSON
        )
        return extractSynonyms(raw, exclude: target, limit: limit)
    }

    private func buildSynonymsPrompt(word: String, lineContext: String, limit: Int) -> String {
        let trimmedContext = lineContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextLine = String(trimmedContext.prefix(240))
        let contextBlock = contextLine.isEmpty ? "(no surrounding line)" : contextLine
        return """
        You are RhymeAI's word inspector. Given a target word and the lyric line it appears in, return synonyms that could replace the target while preserving meaning, register, and roughly the same syllable count.

        Target word: "\(word)"
        Lyric line: "\(contextBlock)"

        Rules:
        - Provide up to \(limit) synonyms.
        - No multi-word phrases unless they would naturally read as a single concept.
        - No duplicates. Never include the target word itself.
        - Match the tone of the line (slang stays slang, formal stays formal).

        Respond ONLY with a JSON object of the form {"synonyms": ["..."]}. No code fences, no commentary.
        """
    }

    private func extractSynonyms(_ raw: String, exclude: String, limit: Int) -> [String] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let excludeKey = exclude.lowercased()

        var collected: [String] = []
        if let data = cleaned.data(using: .utf8) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["synonyms"] as? [String] {
                collected = arr
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                collected = arr
            }
        }

        if collected.isEmpty {
            collected = cleaned
                .components(separatedBy: .newlines)
                .map { line in
                    line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"',-*•"))
                }
                .filter { !$0.isEmpty }
        }

        var seen = Set<String>()
        var result: [String] = []
        for candidate in collected {
            let word = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            guard !word.isEmpty, word.count <= 32 else { continue }
            let key = word.lowercased()
            if key == excludeKey || !seen.insert(key).inserted { continue }
            result.append(word)
            if result.count >= limit { break }
        }
        return result
    }

    @available(iOS 26.0, *)
    private func callLocalRaw(prompt: String, instructions: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIServiceError.localModelUnavailable(reason: describe(model.availability))
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt, options: Self.localGenerationOptions(maxTokens: 256)).content
    }

    /// Unbounded on-device generation can ramble until it overflows the 4k
    /// context window (observed: a 55s harder-rhyme rewrite dying at 4089
    /// tokens). Capping the response keeps latency and the window in check.
    @available(iOS 26.0, *)
    private static func localGenerationOptions(maxTokens: Int) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }

    // MARK: - Rewrite

    func getRewrite(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        action: RewriteAction,
        fullLyrics: String,
        selection: String,
        currentSection: SongSection = .unknown,
        selectionStart: Int? = nil,
        rejectedCandidates: Set<String> = []
    ) async throws -> String {
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.invalidResponse
        }

        if provider == .local {
            // Gemma engine: route through downloaded GGUF model.
            if Self.shouldUseGemma() {
                return try await callGGUFRewrite(
                    action: action,
                    lyrics: fullLyrics,
                    selection: selection,
                    currentSection: currentSection,
                    selectionStart: selectionStart,
                    rejectedCandidates: rejectedCandidates
                )
            }

            // Apple Intelligence fallback.
            if #available(iOS 26.0, *) {
                return try await callLocalRewrite(
                    action: action,
                    lyrics: fullLyrics,
                    selection: selection,
                    currentSection: currentSection,
                    selectionStart: selectionStart,
                    rejectedCandidates: rejectedCandidates
                )
            }
            throw AIServiceError.localModelUnavailable(reason: "Apple Intelligence rewrites require iOS 26 or later.")
        }

        guard !apiKey.isEmpty else {
            throw AIServiceError.noApiKey(provider: provider.displayName)
        }

        let sectionLabel = Self.explicitSectionLabelAtOffset(
            in: fullLyrics,
            characterOffset: selectionStart
        )
        let prompt = buildRewritePrompt(
            action: action,
            lyrics: fullLyrics,
            selection: selection,
            currentSection: currentSection,
            currentSectionLabel: sectionLabel
        )
        let raw = try await callCloudText(
            provider: provider,
            apiKey: apiKey,
            modelId: modelId,
            prompt: prompt,
            kind: .rawJSON
        )

        if let extracted = extractRewriteField(raw)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extracted.isEmpty {
            return extracted
        }
        throw AIServiceError.decodingError
    }

    func buildRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = .unknown,
        currentSectionLabel: String? = nil
    ) -> String {
        let sectionLabelHint = Self.sectionLabelDirective(currentSectionLabel) ?? ""
        return """
        You are an expert songwriter helping the user rewrite a portion of their song.

        Full lyrics for context:
        \"""
        \(lyrics)
        \"""

        The user has selected the following passage from those lyrics. Rewrite ONLY this passage:
        \"""
        \(selection)
        \"""

        Current song section: \(currentSection.displayName).
        \(currentSection.promptHint)
        \(sectionLabelHint)

        Action: \(action.label)
        Instruction: \(action.instruction)

        Rules:
        - Output the rewritten passage only.
        - Preserve line breaks where present.
        - Do not include the surrounding lyrics, commentary, labels, or markdown.

        Respond ONLY with a JSON object of the form {"rewrite": "..."}. No code fences.
        """
    }

    private func buildLocalRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = .unknown,
        selectionStart: Int? = nil,
        rejectedCandidates: Set<String> = []
    ) -> String {
        let sectionLabelHint = Self.sectionLabelDirective(
            Self.explicitSectionLabelAtOffset(
                in: lyrics,
                characterOffset: selectionStart
            )
        ) ?? ""
        let singleWord = isSingleWordSelection(selection)
        let selectedLine = selectionStart.flatMap { lyricLine(at: $0, in: lyrics) }
        let rejectedKeys = rewriteRejectKeys(selection: selection, rejectedCandidates: rejectedCandidates)
        let rejectedRule = singleWord && !rejectedKeys.isEmpty
            ? "Do not return any of these rejected words: \(rejectedKeys.sorted().joined(separator: ", "))."
            : ""
        let taskLine = singleWord
            ? "Replace the selected word with a different word that fits the song."
            : "Rewrite the selected passage from this song."
        let outputRules = singleWord
            ? """
            Return exactly one replacement word.
            The replacement must be different from the selected word.
            Do not return "\(selection)".
            \(rejectedRule)
            No quotes, no labels, no commentary.
            """
            : """
            Reply with the rewritten passage only.
            Preserve line breaks if the selection has multiple lines.
            No quotes, no labels, no commentary.
            """
        return """
        \(taskLine)
        Current song section: \(currentSection.displayName).
        \(currentSection.promptHint)
        \(sectionLabelHint)
        Action: \(action.label).
        Instruction: \(Self.localRewriteInstruction(for: action))

        Lyrics so far:
        \(lyrics)

        \(selectedLine.map { "Line containing the selected word:\n\($0)\n" } ?? "")
        Selected passage:
        \(selection)

        Rules:
        \(outputRules)
        """
    }

    /// Apple's on-device guardrails reject the cloud punch-up wording
    /// ("visceral", "aggressive", "hit harder") as unsafe content, so the
    /// local prompt uses a softer instruction with the same creative intent.
    /// Cloud providers keep RewriteAction.instruction unchanged.
    private static func localRewriteInstruction(for action: RewriteAction) -> String {
        switch action {
        case .punchUp:
            return "Rewrite this passage with sharper, bolder, more vivid imagery. Preserve meaning and rhyme positions. Avoid clichés. Make every line land with more impact."
        case .rephrase, .harderRhyme:
            return action.instruction
        }
    }

    private static func geminiURL(modelId: String, method: String, query: String? = nil) throws -> URL {
        let base = geminiBaseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var urlString = "\(base)/models/\(modelId):\(method)"
        if let query, !query.isEmpty {
            urlString += "?\(query)"
        }
        guard let url = URL(string: urlString) else { throw AIServiceError.invalidResponse }
        return url
    }

    private static var geminiBaseURLString: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-in-memory-store"),
           let override = ProcessInfo.processInfo.environment["RHYMEAI_GEMINI_BASE_URL"],
           !override.isEmpty {
            return override
        }
        #endif
        return "https://generativelanguage.googleapis.com/v1beta"
    }

    @available(iOS 26.0, *)
    private func callLocalRewrite(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection,
        selectionStart: Int?,
        rejectedCandidates: Set<String>
    ) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIServiceError.localModelUnavailable(reason: describe(model.availability))
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "You are an expert songwriter. Rewrite passages only. Output the rewrite only — no quotes, no commentary."
        )

        if !isSingleWordSelection(selection) {
            let prompt = buildLocalRewritePrompt(
                action: action,
                lyrics: lyrics,
                selection: selection,
                currentSection: currentSection,
                selectionStart: selectionStart
            )
            let content: String
            do {
                content = try await session.respond(to: prompt, options: Self.localGenerationOptions(maxTokens: 256)).content
            } catch {
                throw Self.mapLocalGenerationError(error)
            }
            let parsed = cleanLocalRewrite(content, selection: selection)
            guard !parsed.isEmpty else {
                throw AIServiceError.decodingError
            }
            return parsed
        }

        let context = singleWordRewriteContext(lyrics: lyrics, selection: selection, selectionStart: selectionStart)
        var rejectedKeys = rewriteRejectKeys(selection: selection, rejectedCandidates: rejectedCandidates)
        var generationError: Error?
        for _ in 0..<Self.localRewriteAttempts {
            let prompt = buildLocalRewritePrompt(
                action: action,
                lyrics: lyrics,
                selection: selection,
                currentSection: currentSection,
                selectionStart: selectionStart,
                rejectedCandidates: rejectedKeys
            )
            let content: String
            do {
                content = try await session.respond(to: prompt, options: Self.localGenerationOptions(maxTokens: 32)).content
            } catch {
                // Guardrail refusal or transient generation failure: keep the
                // deterministic fallback table in play instead of surfacing a
                // raw FoundationModels error for a single-word selection.
                generationError = error
                continue
            }
            let parsed = cleanLocalRewrite(content, selection: selection)
            let accepted = acceptLocalSingleWordRewrite(
                candidate: parsed,
                selection: selection,
                action: action,
                context: context,
                rejectedCandidates: rejectedKeys
            )
            if !accepted.isEmpty {
                return accepted
            }
            let parsedKey = normalizeSuggestionKey(parsed)
            if !parsedKey.isEmpty {
                rejectedKeys.insert(parsedKey)
            }
        }

        let fallback = fallbackLocalSingleWordRewrite(
            selection: selection,
            action: action,
            context: context,
            rejectedCandidates: rejectedKeys
        )
        if !fallback.isEmpty {
            return fallback
        }
        if let generationError {
            throw Self.mapLocalGenerationError(generationError)
        }
        if action == .harderRhyme {
            throw AIServiceError.noSafeSingleWordRhyme
        }
        throw AIServiceError.decodingError
    }

    /// Surfaces on-device guardrail refusals as the recognized safety error
    /// instead of a raw FoundationModels failure.
    @available(iOS 26.0, *)
    private static func mapLocalGenerationError(_ error: Error) -> Error {
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .guardrailViolation = generationError {
            return AIServiceError.blockedResponse
        }
        return error
    }

    func acceptLocalSingleWordRewrite(candidate: String, selection: String, action: RewriteAction) -> String {
        acceptLocalSingleWordRewrite(
            candidate: candidate,
            selection: selection,
            action: action,
            context: nil,
            rejectedCandidates: []
        )
    }

    func acceptLocalSingleWordRewrite(
        candidate: String,
        selection: String,
        action: RewriteAction,
        context: SingleWordRewriteContext?,
        rejectedCandidates: Set<String>
    ) -> String {
        let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSingleWordSelection(word) else { return "" }
        let originalKey = normalizeSuggestionKey(selection)
        let candidateKey = normalizeSuggestionKey(word)
        guard !candidateKey.isEmpty,
              candidateKey != originalKey,
              !rewriteRejectKeys(selection: selection, rejectedCandidates: rejectedCandidates).contains(candidateKey) else {
            return ""
        }

        if action == .harderRhyme {
            let originalSyllables = max(ProsodyAnalyzer.countWord(selection), 1)
            let candidateSyllables = max(ProsodyAnalyzer.countWord(word), 1)
            guard candidateSyllables <= originalSyllables + 1 else { return "" }
            guard harderRhymeFitsContext(selection: selection, candidate: word, context: context) else { return "" }
        }

        return word
    }

    func fallbackLocalSingleWordRewrite(
        selection: String,
        action: RewriteAction,
        context: SingleWordRewriteContext? = nil,
        rejectedCandidates: Set<String> = []
    ) -> String {
        let originalKey = normalizeSuggestionKey(selection)
        guard !originalKey.isEmpty else { return "" }
        let candidates: [String]
        switch action {
        case .rephrase:
            candidates = Self.fallbackRephraseWords[originalKey] ?? []
        case .harderRhyme:
            candidates = Self.fallbackHarderRhymeWords[originalKey] ?? []
        case .punchUp:
            candidates = Self.fallbackPunchUpWords[originalKey] ?? []
        }
        return candidates.first { candidate in
            !acceptLocalSingleWordRewrite(
                candidate: candidate,
                selection: selection,
                action: action,
                context: context,
                rejectedCandidates: rejectedCandidates
            ).isEmpty
        } ?? ""
    }

    func singleWordRewriteContext(
        lyrics: String,
        selection: String,
        selectionStart: Int?
    ) -> SingleWordRewriteContext? {
        guard let selectionStart,
              selectionStart >= 0,
              selectionStart <= lyrics.count,
              let startIndex = lyrics.index(lyrics.startIndex, offsetBy: selectionStart, limitedBy: lyrics.endIndex) else {
            return nil
        }
        let lineStart = lyrics[..<startIndex].lastIndex(of: "\n").map { lyrics.index(after: $0) } ?? lyrics.startIndex
        let lineEnd = lyrics[startIndex...].firstIndex(of: "\n") ?? lyrics.endIndex
        let line = String(lyrics[lineStart..<lineEnd])
        let relativeStart = lyrics.distance(from: lineStart, to: startIndex)
        let relativeEnd = relativeStart + selection.count
        let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}'-]+"#)
        let nsLine = line as NSString
        let matches = regex?.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) ?? []
        guard let selectedIndex = matches.firstIndex(where: { match in
            relativeStart <= match.range.upperBound && relativeEnd >= match.range.location
        }) else {
            return nil
        }
        let selectedRange = matches[selectedIndex].range
        let trailing = nsLine.substring(from: selectedRange.upperBound)
        return SingleWordRewriteContext(
            line: line,
            previousWord: selectedIndex > 0 ? nsLine.substring(with: matches[selectedIndex - 1].range) : nil,
            nextWord: selectedIndex + 1 < matches.count ? nsLine.substring(with: matches[selectedIndex + 1].range) : nil,
            isLineEnding: !trailing.contains(where: \.isLetter) && !trailing.contains(where: \.isNumber)
        )
    }

    private func harderRhymeFitsContext(
        selection: String,
        candidate: String,
        context: SingleWordRewriteContext?
    ) -> Bool {
        guard let context else { return true }
        let originalKey = normalizeSuggestionKey(selection)
        let candidateKey = normalizeSuggestionKey(candidate)
        let previousKey = context.previousWord.map(normalizeSuggestionKey) ?? ""
        let nextKey = context.nextWord.map(normalizeSuggestionKey) ?? ""

        guard context.isLineEnding else { return false }
        if originalKey == "make", nextKey == "believe" { return false }
        if previousKey == "phone", ["walls", "falls", "halls"].contains(candidateKey) { return false }
        return harderRhymeSoundsClose(selection: selection, candidate: candidate)
    }

    private func harderRhymeSoundsClose(selection: String, candidate: String) -> Bool {
        let originalKey = normalizeSuggestionKey(selection)
        let candidateKey = normalizeSuggestionKey(candidate)
        let fallbackKeys = Set((Self.fallbackHarderRhymeWords[originalKey] ?? []).map(normalizeSuggestionKey))
        if fallbackKeys.contains(candidateKey) { return true }

        let originalRhymeKeys = Set(ProsodyAnalyzer.rhymeKeys(for: selection, maxDepth: 2))
        let candidateRhymeKeys = Set(ProsodyAnalyzer.rhymeKeys(for: candidate, maxDepth: 2))
        if !originalRhymeKeys.isEmpty, !candidateRhymeKeys.isEmpty {
            return !originalRhymeKeys.intersection(candidateRhymeKeys).isEmpty
        }

        let originalTail = spellingRhymeTail(originalKey)
        let candidateTail = spellingRhymeTail(candidateKey)
        return !originalTail.isEmpty && originalTail == candidateTail
    }

    private func spellingRhymeTail(_ word: String) -> String {
        var normalized = word
        [
            ("ee", "i"),
            ("ea", "i"),
            ("ie", "i"),
            ("igh", "i"),
            ("ai", "a"),
            ("ay", "a")
        ].forEach { from, to in
            normalized = normalized.replacingOccurrences(of: from, with: to)
        }
        return String(normalized.suffix(3))
    }

    private func lyricLine(at selectionStart: Int, in lyrics: String) -> String? {
        guard selectionStart >= 0,
              selectionStart <= lyrics.count,
              let startIndex = lyrics.index(lyrics.startIndex, offsetBy: selectionStart, limitedBy: lyrics.endIndex) else {
            return nil
        }
        let lineStart = lyrics[..<startIndex].lastIndex(of: "\n").map { lyrics.index(after: $0) } ?? lyrics.startIndex
        let lineEnd = lyrics[startIndex...].firstIndex(of: "\n") ?? lyrics.endIndex
        let line = String(lyrics[lineStart..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    private func rewriteRejectKeys(selection: String, rejectedCandidates: Set<String>) -> Set<String> {
        Set(rejectedCandidates.union([selection]).map(normalizeSuggestionKey).filter { !$0.isEmpty })
    }

    func cleanLocalRewrite(_ response: String, selection: String? = nil) -> String {
        let stripped = stripLocalModelArtifacts(response)
        let extracted = extractRewriteField(stripped).map(stripLocalModelArtifacts) ?? stripped
        var cleaned = extracted
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selection.map(isSingleWordSelection) == true {
            cleaned = cleanSingleWordRewrite(cleaned, selection: selection ?? "")
        } else {
            cleaned = cleanRewritePassage(cleaned)
        }
        if let selection, normalizeSuggestionKey(cleaned) == normalizeSuggestionKey(selection) {
            return ""
        }
        return cleaned
    }

    private func extractRewriteField(_ text: String) -> String? {
        var cleaned = stripLocalModelArtifacts(text)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj["rewrite"] as? String else {
            return nil
        }
        return value
    }

    private func cleanRewritePassage(_ response: String) -> String {
        let cleaned = stripLocalModelArtifacts(response)
            .components(separatedBy: .newlines)
            .compactMap { cleanLocalOutputLine($0, maxLength: 240) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containsLocalControlMarker(cleaned) else { return "" }
        return cleaned
    }

    private func cleanSingleWordRewrite(_ response: String, selection: String) -> String {
        let originalKey = normalizeSuggestionKey(selection)
        let labelTokens: Set<String> = [
            "a", "an", "as", "be", "i", "instead", "is", "model", "original",
            "replace", "replacement", "rewrite", "selected", "suggest", "the",
            "try", "turn", "use", "user", "with", "word", "would"
        ]
        let normalized = stripLocalModelArtifacts(response)
            .replacingOccurrences(of: "=>", with: "->")
            .replacingOccurrences(of: ":", with: " ")

        for line in normalized.components(separatedBy: .newlines) {
            let pieces = line
                .components(separatedBy: CharacterSet(charactersIn: ",/|"))
                .flatMap { $0.components(separatedBy: "->") }
            for piece in pieces {
                let tokens = piece.split(whereSeparator: \.isWhitespace).map(String.init)
                let candidates = tokens.isEmpty ? [piece] : tokens
                for candidate in candidates {
                    let word = candidate
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`.!?;:-*•"))
                    let key = normalizeSuggestionKey(word)
                    if !key.isEmpty,
                       key != originalKey,
                       word.count <= 32,
                       !labelTokens.contains(key) {
                        return word
                    }
                }
            }
        }
        return ""
    }

    private func isSingleWordSelection(_ selection: String) -> Bool {
        selection.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[\p{L}\p{N}'-]+$"#, options: .regularExpression) != nil
    }

    private func cleanLocalOutputLine(_ line: String, maxLength: Int) -> String? {
        var cleaned = stripLocalModelArtifacts(line)
        let markerPrefix = #"^(?:_?response>|_?model_response>|assistant_response>|model_response>|assistant:|model:|user:|<?/?(?:start|end)_?(?:of_?)?turn>?\w*)\s*"#
        if let range = cleaned.range(of: markerPrefix, options: [.regularExpression, .caseInsensitive]) {
            cleaned = String(cleaned[range.upperBound...])
        }
        if let range = cleaned.range(of: #"^(?:[-*]\s+|\d+[.)\-:]\s*)"#, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        cleaned = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // gemma-4 spells turn markers as plain text; a sampling derailment can
        // glue a mutated or truncated marker (e.g. "<end_turn>", "<end_") to the
        // end of a good line — strip it instead of rejecting the lyric.
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)(?:\s*<?/?(?:start|end)_?(?:of_?)?turn>?)+\s*$|\s*<[a-z_/]{0,16}$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }
        let markerOnly = #"^(?:_?response>|_?model_response>|assistant_response>|model_response>|<?/?(?:start|end)_?(?:of_?)?turn>?\w*|<[^>]+>|user|model|assistant)\s*$"#
        guard cleaned.range(of: markerOnly, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let promptEcho = #"^(?:task:|theme:|rhyme scheme:|lyrics context:|rules:|return exactly|return only|one suggestion|no numbering|do not|keep each|you are rhymeai|sure[, ]|here are|i can(?:not|'t)|as an ai)"#
        guard cleaned.range(of: promptEcho, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        guard !containsLocalControlMarker(cleaned), cleaned.count <= maxLength else { return nil }
        return cleaned
    }

    private func stripLocalModelArtifacts(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelPayloadPrefix = #"(?is).*(?:<start_?(?:of_?)?turn>\s*model|start_?(?:of_?)?turn>\s*model|_?model_response>|assistant_response>|model_response>)\s*"#
        if let range = cleaned.range(of: modelPayloadPrefix, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        if let range = cleaned.range(of: #"<end_?(?:of_?)?turn>|end_?(?:of_?)?turn>"#, options: [.regularExpression, .caseInsensitive]) {
            cleaned = String(cleaned[..<range.lowerBound])
        }
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)<?/?(?:start|end)_?(?:of_?)?turn>?\w*|_?response>|_?model_response>|assistant_response>|model_response>"#,
            with: "",
            options: .regularExpression
        )
        let filtered = cleaned
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty &&
                    trimmed != "```" &&
                    trimmed.range(of: #"^```json$"#, options: [.regularExpression, .caseInsensitive]) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var unfenced = filtered
        if unfenced.hasPrefix("```json") { unfenced = String(unfenced.dropFirst(7)) }
        if unfenced.hasPrefix("```") { unfenced = String(unfenced.dropFirst(3)) }
        if unfenced.hasSuffix("```") { unfenced = String(unfenced.dropLast(3)) }
        return unfenced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsLocalControlMarker(_ text: String) -> Bool {
        text.range(
            of: #"(?i)<?/?(?:start|end)_?(?:of_?)?turn>?\w*|_?response>|_?model_response>|assistant_response>|model_response>"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - HTTP

    private func httpPost(url: URL, headers: [String: String], body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AIServiceError.requestTimedOut
        } catch is URLError {
            throw AIServiceError.networkUnavailable
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIServiceError.apiError(
                statusCode: httpResponse.statusCode,
                message: AIService.userFacingStatusMessage(for: httpResponse.statusCode)
            )
        }
        return data
    }

    static func userFacingStatusMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            return "Provider rejected the request — check your API key in Settings."
        case 404:
            return "Provider could not find the requested model — pick another in Settings."
        case 429:
            return "Provider rate limit reached — wait a moment and retry."
        case 500...599:
            return "Provider service error — try again shortly."
        default:
            return "Provider request failed (status \(statusCode))."
        }
    }

    static func geminiText(from json: [String: Any]) throws -> String {
        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           promptFeedback["blockReason"] != nil {
            throw AIServiceError.blockedResponse
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            throw AIServiceError.decodingError
        }

        if let finishReason = candidate["finishReason"] as? String,
           ["SAFETY", "RECITATION", "PROHIBITED_CONTENT", "SPII", "OTHER"].contains(finishReason) {
            throw AIServiceError.blockedResponse
        }

        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AIServiceError.decodingError
        }
        return text
    }

    // MARK: - Parsing

    func parseSuggestionList(_ text: String) -> [String] {
        parseSuggestionList(text, limit: Self.suggestionCount)
    }

    func parseSuggestionList(_ text: String, limit: Int) -> [String] {
        let parsed = parseJsonArray(text, limit: limit)
        let candidates = parsed.isEmpty ? parseLines(text) : parsed
        var seen = Set<String>()
        var result: [String] = []

        for candidate in candidates {
            guard let cleaned = cleanSuggestionLine(candidate) else { continue }
            let key = normalizeSuggestionKey(cleaned)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(cleaned)
            if result.count >= limit { break }
        }
        return result
    }

    private func parseJsonArray(_ text: String, limit: Int) -> [String] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip code fences
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try parsing as a direct JSON array
        if let data = cleaned.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return Array(array.prefix(limit))
        }

        // Try parsing as a JSON object containing an array
        if let data = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for value in obj.values {
                if let array = value as? [String] {
                    return Array(array.prefix(limit))
                }
            }
        }

        return []
    }

    private func parseLines(_ text: String) -> [String] {
        let normalized = text.contains("\n")
            ? text
            : text
                .replacingOccurrences(of: "\\r\\n", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
        return normalized.components(separatedBy: .newlines)
    }
}
