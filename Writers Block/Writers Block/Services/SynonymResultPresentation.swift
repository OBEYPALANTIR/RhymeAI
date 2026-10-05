nonisolated enum SynonymRecoveryAction: Equatable, Sendable {
    case retry
    case openSettings
}

/// What the inspector's rhyme sections show. A lookup that is still running
/// (no matches yet) is not the same as a finished lookup that found nothing:
/// the first lookup after launch can wait seconds for the rhyme index.
nonisolated enum RhymeResultPresentation {
    enum State: Equatable {
        case finding
        case results(RhymeMatches)
    }

    static let findingMessage = "Finding rhymes…"

    static func state(for matches: RhymeMatches?) -> State {
        matches.map(State.results) ?? .finding
    }

    /// Spoken when results replace the finding state. Lookups that finish
    /// before a listener could have heard "Finding rhymes" stay silent.
    static func announcement(for matches: RhymeMatches, waited: Double) -> String? {
        guard waited >= 1 else { return nil }
        let count = matches.perfect.count + matches.multi.count + matches.near.count
        return count == 0 ? "No rhymes found" : "Rhymes loaded"
    }
}

nonisolated enum SynonymResultPresentation {
    static func recoveryAction(resultCount: Int, error: Error?) -> SynonymRecoveryAction? {
        guard let error else { return nil }
        if let serviceError = error as? AIServiceError,
           case .noApiKey = serviceError {
            return .openSettings
        }
        return resultCount < SynonymGenerationPipeline.minimumUsefulCount ? .retry : nil
    }

    /// What the inspector shows when a synonym request fails. The app's own
    /// errors already read as sentences; anything else (a framework error
    /// such as "FoundationModels.LanguageModelError error -1") is replaced
    /// with a line that says what to do next.
    static func message(for error: Error) -> String {
        if let serviceError = error as? AIServiceError,
           let description = serviceError.errorDescription {
            return description
        }
        return "Synonyms aren't available from this model right now. Try again, or choose another provider in Settings."
    }
}
