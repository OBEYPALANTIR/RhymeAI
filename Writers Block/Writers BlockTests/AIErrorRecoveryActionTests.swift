import Testing
@testable import Writers_Block

struct AIErrorRecoveryActionTests {
    @Test
    func missingAPIKeyRequiresSettings() {
        let message = "No API key set. Go to Settings to add your Gemini API key."

        #expect(AIErrorRecoveryAction(errorMessage: message) == .openSettings)
    }

    @Test
    func providerFailureAllowsRetry() {
        let message = "Provider request failed — check your connection and try again."

        #expect(AIErrorRecoveryAction(errorMessage: message) == .retry)
    }
}
