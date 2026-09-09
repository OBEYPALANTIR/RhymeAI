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
}
