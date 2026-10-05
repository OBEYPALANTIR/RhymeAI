nonisolated enum SynonymRecoveryAction: Equatable, Sendable {
    case retry
    case openSettings
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
