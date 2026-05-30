import Foundation
import FoundationModels

enum AIServiceError: LocalizedError {
    case noApiKey(provider: String)
    case localModelUnavailable(reason: String)
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case decodingError

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
        case .decodingError:
            return "Failed to parse AI response."
        }
    }
}

struct AIService {
    private static let suggestionCount = 6

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
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) async throws -> [String] {
        if provider == .local {
            if #available(iOS 26.0, *) {
                let prompt = buildLocalPrompt(
                    theme: theme,
                    lyrics: lyrics,
                    targetRhymeLine: targetRhymeLine,
                    rhymeType: rhymeType,
                    currentLetter: currentLetter,
                    currentSection: currentSection,
                    useWholeSongContext: useWholeSongContext
                )
                return try await callLocal(prompt: prompt)
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
            complexity: complexity,
            useWholeSongContext: useWholeSongContext
        )

        switch provider {
        case .gemini:
            return try await callGemini(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .openai:
            return try await callOpenAI(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .claude:
            return try await callClaude(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .local:
            throw AIServiceError.invalidResponse
        }
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
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if provider == .local {
                        // Local model already token-streams internally; needs its own AsyncStream surface (follow-up).
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
                        complexity: complexity,
                        useWholeSongContext: useWholeSongContext
                    )

                    let tokens: AsyncThrowingStream<String, Error>
                    switch provider {
                    case .gemini:
                        tokens = streamGeminiTokens(apiKey: apiKey, modelId: modelId, prompt: prompt)
                    case .openai:
                        tokens = streamOpenAITokens(apiKey: apiKey, modelId: modelId, prompt: prompt)
                    case .claude:
                        tokens = streamClaudeTokens(apiKey: apiKey, modelId: modelId, prompt: prompt)
                    case .local:
                        continuation.finish()
                        return
                    }

                    try await emitLines(from: tokens, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func emitLines(
        from tokens: AsyncThrowingStream<String, Error>,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var buffer = ""
        var seen = Set<String>()
        var emitted = 0

        for try await chunk in tokens {
            buffer += chunk
            while emitted < Self.suggestionCount, let newlineIdx = buffer.firstIndex(of: "\n") {
                let rawLine = String(buffer[..<newlineIdx])
                buffer = String(buffer[buffer.index(after: newlineIdx)...])
                if let cleaned = cleanSuggestionLine(rawLine) {
                    let key = normalizeSuggestionKey(cleaned)
                    if !key.isEmpty, seen.insert(key).inserted {
                        continuation.yield(cleaned)
                        emitted += 1
                    }
                }
            }
            if emitted >= Self.suggestionCount { break }
        }

        if emitted < Self.suggestionCount {
            let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty, let cleaned = cleanSuggestionLine(remaining) {
                let key = normalizeSuggestionKey(cleaned)
                if !key.isEmpty, seen.insert(key).inserted {
                    continuation.yield(cleaned)
                }
            }
        }
    }

    private func streamGeminiTokens(
        apiKey: String,
        modelId: String,
        prompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):streamGenerateContent?alt=sse"
                    guard let url = URL(string: urlString) else {
                        throw AIServiceError.invalidResponse
                    }
                    let body: [String: Any] = [
                        "contents": [["parts": [["text": prompt]]]]
                    ]
                    let payloads = httpPostStream(
                        url: url,
                        headers: [
                            "Content-Type": "application/json",
                            "x-goog-api-key": apiKey
                        ],
                        body: try JSONSerialization.data(withJSONObject: body)
                    )
                    for try await payload in payloads {
                        if let chunk = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                           let candidates = chunk["candidates"] as? [[String: Any]],
                           let content = candidates.first?["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let text = parts.first?["text"] as? String {
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

    private func streamOpenAITokens(
        apiKey: String,
        modelId: String,
        prompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
                        throw AIServiceError.invalidResponse
                    }
                    let body: [String: Any] = [
                        "model": modelId,
                        "messages": [["role": "user", "content": prompt]],
                        "stream": true,
                        "temperature": 0.8
                    ]
                    let payloads = httpPostStream(
                        url: url,
                        headers: [
                            "Content-Type": "application/json",
                            "Authorization": "Bearer \(apiKey)",
                            "Accept": "text/event-stream"
                        ],
                        body: try JSONSerialization.data(withJSONObject: body)
                    )
                    for try await payload in payloads {
                        if let chunk = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                           let choices = chunk["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            continuation.yield(content)
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

    private func streamClaudeTokens(
        apiKey: String,
        modelId: String,
        prompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                        throw AIServiceError.invalidResponse
                    }
                    let body: [String: Any] = [
                        "model": modelId,
                        "max_tokens": 1024,
                        "stream": true,
                        "messages": [["role": "user", "content": prompt]]
                    ]
                    let payloads = httpPostStream(
                        url: url,
                        headers: [
                            "Content-Type": "application/json",
                            "x-api-key": apiKey,
                            "anthropic-version": "2023-06-01",
                            "Accept": "text/event-stream"
                        ],
                        body: try JSONSerialization.data(withJSONObject: body)
                    )
                    for try await payload in payloads {
                        if let chunk = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                           chunk["type"] as? String == "content_block_delta",
                           let delta = chunk["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
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
                        for try await _ in bytes {}
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
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        if let range = cleaned.range(of: #"^(?:[-*]\s+|\d+[.)]\s*)"#, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")), cleaned.count > 1 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.count > 140 { return nil }
        return cleaned
    }

    private func normalizeSuggestionKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    // MARK: - Prompt Builder

    private func buildPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = .unknown,
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) -> String {
        let effectiveTheme = useWholeSongContext
            ? "Whole song context enabled; infer the theme from the full lyrics."
            : (theme.isEmpty ? "No specific theme provided" : theme)

        let rhymeInstruction: String
        if let target = targetRhymeLine {
            rhymeInstruction = """
            Crucially, the new line MUST end with a **\(rhymeType.displayName)** to this specific line: "\(target)".
            """
        } else {
            rhymeInstruction = """
            Since this is a new rhyme sound ("\(currentLetter)"), the new line should introduce a new end-rhyme that fits the meter and theme.
            """
        }

        let rhymeAdherence = targetRhymeLine != nil
            ? ", and strictly adhere to the requested rhyme type (\(rhymeType.displayName))"
            : ""
        let songContextInstruction = useWholeSongContext
            ? "Analyze the whole song for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary. Make each suggestion feel connected to the entire song while still fitting the immediate target line and rhyme scheme."
            : "Prioritize the immediate writing context, current stanza, target line, rhyme scheme, and provided theme/context."

        return """
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
        \(rhymeInstruction)
        \(songContextInstruction)

        Complexity level: \(complexity.label). \(complexity.promptHint)

        Provide \(Self.suggestionCount) creative, poetic, and contextually relevant suggestions for the next line.
        Make sure the rhythm and meter match the style of the current lyrics\(rhymeAdherence).

        Respond with exactly \(Self.suggestionCount) lines, one suggestion per line. No numbering, no bullets, no quotes, no markdown, no code fences, and no commentary — just the bare suggestion lines.
        """
    }

    // MARK: - Gemini

    private func callGemini(apiKey: String, modelId: String, prompt: String) async throws -> [String] {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent"
        guard let url = URL(string: urlString) else { throw AIServiceError.invalidResponse }

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ]
        ]

        let data = try await httpPost(
            url: url,
            headers: [
                "Content-Type": "application/json",
                "x-goog-api-key": apiKey
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AIServiceError.decodingError
        }

        let results = parseJsonArray(text)
        return results.isEmpty ? parseLines(text) : results
    }

    // MARK: - OpenAI

    private func callOpenAI(apiKey: String, modelId: String, prompt: String) async throws -> [String] {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIServiceError.invalidResponse
        }

        let body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        let data = try await httpPost(
            url: url,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIServiceError.decodingError
        }

        let results = parseJsonArray(content)
        return results.isEmpty ? parseLines(content) : results
    }

    // MARK: - Claude

    private func callClaude(apiKey: String, modelId: String, prompt: String) async throws -> [String] {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIServiceError.invalidResponse
        }

        let body: [String: Any] = [
            "model": modelId,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        let data = try await httpPost(
            url: url,
            headers: [
                "Content-Type": "application/json",
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let text = contentArray.first?["text"] as? String else {
            throw AIServiceError.decodingError
        }

        let results = parseJsonArray(text)
        return results.isEmpty ? parseLines(text) : results
    }

    // MARK: - Local

    private func buildLocalPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        currentLetter: String,
        currentSection: SongSection = .unknown,
        useWholeSongContext: Bool
    ) -> String {
        let rhymeHint: String
        if let targetRhymeLine {
            rhymeHint = "Each line must rhyme (\(rhymeType.displayName)) with: \"\(targetRhymeLine)\""
        } else {
            rhymeHint = "Start a new rhyme sound for letter \"\(currentLetter)\"."
        }
        let songContextInstruction = useWholeSongContext
            ? "Use the full song for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary."
            : "Use the immediate stanza, rhyme target, and theme first."
        let themeClause = !useWholeSongContext && !theme.isEmpty ? " about \(theme)" : ""

        return """
        Write \(Self.suggestionCount) next lines for this song\(themeClause).
        Current song section: \(currentSection.displayName).
        \(currentSection.promptHint)
        \(rhymeHint)
        \(songContextInstruction)

        Lyrics so far:
        \(lyrics)

        Reply with exactly \(Self.suggestionCount) lines, one per line, no numbering, no extra text.
        """
    }

    @available(iOS 26.0, *)
    private func callLocal(prompt: String) async throws -> [String] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIServiceError.localModelUnavailable(reason: describe(model.availability))
        }

        let session = LanguageModelSession(
            model: model,
            instructions: "You are an expert songwriter and lyricist. Return concise lyric line suggestions only."
        )
        let response = try await session.respond(to: prompt)
        let results = parseJsonArray(response.content)
        let parsed = results.isEmpty ? parseLines(response.content) : results
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

        if provider == .local {
            if #available(iOS 26.0, *) {
                let prompt = buildSynonymsPrompt(word: target, lineContext: lineContext, limit: limit)
                let raw = try await callLocalRaw(prompt: prompt, instructions: "You are an expert lexicographer. Reply ONLY with the requested JSON object.")
                return extractSynonyms(raw, exclude: target, limit: limit)
            }
            throw AIServiceError.localModelUnavailable(reason: "Apple Intelligence synonyms require iOS 26 or later.")
        }

        guard !apiKey.isEmpty else {
            throw AIServiceError.noApiKey(provider: provider.displayName)
        }

        let prompt = buildSynonymsPrompt(word: target, lineContext: lineContext, limit: limit)
        let raw: String
        switch provider {
        case .gemini:
            raw = try await callGeminiRaw(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .openai:
            raw = try await callOpenAIRaw(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .claude:
            raw = try await callClaudeRaw(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .local:
            throw AIServiceError.invalidResponse
        }
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
        return try await session.respond(to: prompt).content
    }

    // MARK: - Rewrite

    func getRewrite(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        action: RewriteAction,
        fullLyrics: String,
        selection: String,
        currentSection: SongSection = .unknown
    ) async throws -> String {
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.invalidResponse
        }

        if provider == .local {
            if #available(iOS 26.0, *) {
                let prompt = buildLocalRewritePrompt(action: action, lyrics: fullLyrics, selection: selection, currentSection: currentSection)
                return try await callLocalRewrite(prompt: prompt)
            }
            throw AIServiceError.localModelUnavailable(reason: "Apple Intelligence rewrites require iOS 26 or later.")
        }

        guard !apiKey.isEmpty else {
            throw AIServiceError.noApiKey(provider: provider.displayName)
        }

        let prompt = buildRewritePrompt(action: action, lyrics: fullLyrics, selection: selection, currentSection: currentSection)
        let raw: String
        switch provider {
        case .gemini:
            raw = try await callGeminiRaw(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .openai:
            raw = try await callOpenAIRaw(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .claude:
            raw = try await callClaudeRaw(apiKey: apiKey, modelId: modelId, prompt: prompt)
        case .local:
            throw AIServiceError.invalidResponse
        }

        if let extracted = extractRewriteField(raw)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extracted.isEmpty {
            return extracted
        }
        throw AIServiceError.decodingError
    }

    private func buildRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = .unknown
    ) -> String {
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
        currentSection: SongSection = .unknown
    ) -> String {
        return """
        Rewrite the selected passage from this song.
        Current song section: \(currentSection.displayName).
        \(currentSection.promptHint)
        Action: \(action.label).
        Instruction: \(action.instruction)

        Lyrics so far:
        \(lyrics)

        Selected passage:
        \(selection)

        Reply with the rewritten passage only. No quotes, no labels, no commentary.
        """
    }

    private func callGeminiRaw(apiKey: String, modelId: String, prompt: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent"
        guard let url = URL(string: urlString) else { throw AIServiceError.invalidResponse }

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json"]
        ]
        let data = try await httpPost(
            url: url,
            headers: [
                "Content-Type": "application/json",
                "x-goog-api-key": apiKey
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AIServiceError.decodingError
        }
        return text
    }

    private func callOpenAIRaw(apiKey: String, modelId: String, prompt: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIServiceError.invalidResponse
        }
        let body: [String: Any] = [
            "model": modelId,
            "messages": [["role": "user", "content": prompt]],
            "response_format": ["type": "json_object"]
        ]
        let data = try await httpPost(
            url: url,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIServiceError.decodingError
        }
        return content
    }

    private func callClaudeRaw(apiKey: String, modelId: String, prompt: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIServiceError.invalidResponse
        }
        let body: [String: Any] = [
            "model": modelId,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]]
        ]
        let data = try await httpPost(
            url: url,
            headers: [
                "Content-Type": "application/json",
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let text = contentArray.first?["text"] as? String else {
            throw AIServiceError.decodingError
        }
        return text
    }

    @available(iOS 26.0, *)
    private func callLocalRewrite(prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIServiceError.localModelUnavailable(reason: describe(model.availability))
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "You are an expert songwriter. Rewrite passages only. Output the rewrite only — no quotes, no commentary."
        )
        let response = try await session.respond(to: prompt)
        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extracted = extractRewriteField(trimmed) { return extracted }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func extractRewriteField(_ text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - HTTP

    private func httpPost(url: URL, headers: [String: String], body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
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

    // MARK: - Parsing

    private func parseJsonArray(_ text: String) -> [String] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip code fences
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try parsing as a direct JSON array
        if let data = cleaned.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return Array(array.prefix(Self.suggestionCount))
        }

        // Try parsing as a JSON object containing an array
        if let data = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for value in obj.values {
                if let array = value as? [String] {
                    return Array(array.prefix(Self.suggestionCount))
                }
            }
        }

        return []
    }

    private func parseLines(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { line in
                // Strip numbering like "1. " or "1) "
                var cleaned = line.trimmingCharacters(in: .whitespaces)
                if let range = cleaned.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) {
                    cleaned = String(cleaned[range.upperBound...])
                }
                // Strip surrounding quotes
                if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
                    cleaned = String(cleaned.dropFirst().dropLast())
                }
                return cleaned
            }
            .filter { !$0.isEmpty }

        return Array(lines.prefix(Self.suggestionCount))
    }
}
