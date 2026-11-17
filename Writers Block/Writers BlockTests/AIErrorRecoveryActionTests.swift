import Testing
@testable import Writers_Block

struct AIErrorRecoveryActionTests {
    @Test
    func missingAPIKeyRequiresSettings() {
        let message = "No API key set. Go to Settings to add your Gemini API key."

        #expect(AIErrorRecoveryAction(errorMessage: message) == .openSettings)
    }

    @Test
    func localGenerationFailureRequiresSettings() throws {
        let message = try #require(AIServiceError.localGenerationFailed(gemmaDownloadAvailable: true).errorDescription)

        #expect(AIErrorRecoveryAction(errorMessage: message) == .openSettings)
    }

    @Test
    func missingLocalModelRequiresModelSetup() throws {
        let message = try #require(AIServiceError.localModelUnavailable(reason: AIService.noGGUFModelReason).errorDescription)

        #expect(AIErrorRecoveryAction(errorMessage: message) == .setUpModel)
    }

    @Test(arguments: [
        AIService.rewritesRequireIOS26Reason,
        AIService.suggestionsRequireIOS26Reason,
        AIService.synonymsRequireIOS26Reason,
        AIService.appleIntelligenceNotEnabledReason,
        AIService.deviceNotEligibleReason,
    ])
    func appleIntelligenceUnavailableRequiresModelSetup(reason: String) throws {
        let message = try #require(AIServiceError.localModelUnavailable(reason: reason).errorDescription)

        #expect(AIErrorRecoveryAction(errorMessage: message) == .setUpModel)
    }

    @Test
    func modelStillDownloadingAllowsRetry() throws {
        let message = try #require(AIServiceError.localModelUnavailable(reason: AIService.modelNotReadyReason).errorDescription)

        #expect(AIErrorRecoveryAction(errorMessage: message) == .retry)
    }

    @Test
    func providerFailureAllowsRetry() {
        let message = "Provider request failed — check your connection and try again."

        #expect(AIErrorRecoveryAction(errorMessage: message) == .retry)
    }
}
