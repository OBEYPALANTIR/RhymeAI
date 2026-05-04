import Foundation

enum AIServiceError: LocalizedError {
    case noApiKey(provider: String)
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .noApiKey(let provider):
            return "No API key set. Go to Settings to add your \(provider) API key."
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
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) async throws -> [String] {
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
        }
    }

    // MARK: - Prompt Builder

    private func buildPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        complexity: RhymeComplexity,
        useWholeSongContext: Bool
    ) -> String {
        let effectiveTheme = theme.isEmpty ? "No specific theme provided" : theme

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
        \(rhymeInstruction)
        \(songContextInstruction)

        Complexity level: \(complexity.label). \(complexity.promptHint)

        Provide \(Self.suggestionCount) creative, poetic, and contextually relevant suggestions for the next line.
        Make sure the rhythm and meter match the style of the current lyrics\(rhymeAdherence).

        Respond ONLY with a JSON array of \(Self.suggestionCount) strings. No markdown, no code fences, just the raw JSON array.
        """
    }

    // MARK: - Gemini

    private func callGemini(apiKey: String, modelId: String, prompt: String) async throws -> [String] {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw AIServiceError.invalidResponse }

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "responseMimeType": "application/json"
            ]
        ]

        let data = try await httpPost(
            url: url,
            headers: ["Content-Type": "application/json"],
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
            ],
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
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIServiceError.apiError(statusCode: httpResponse.statusCode, message: body)
        }
        return data
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
