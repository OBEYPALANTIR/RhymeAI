import XCTest
@testable import Writers_Block

final class LocalProviderSmokeTests: XCTestCase {
    @MainActor
    func testLocalProviderReturnsTextOrAvailabilityMessage() async throws {
        let service = AIService()
        let lyrics = "[Verse]\nI keep a notebook under neon rain\nEvery margin learns my name"

        do {
            let suggestions = try await service.getSuggestions(
                provider: .local,
                apiKey: "",
                modelId: AIModel.localModel.id,
                theme: "late-night writing",
                lyrics: lyrics,
                targetRhymeLine: "I keep a notebook under neon rain",
                rhymeType: .perfect,
                rhymeScheme: "AABB",
                currentLetter: "A",
                currentSection: .verse,
                complexity: .moderate,
                useWholeSongContext: false
            )
            XCTAssertFalse(suggestions.isEmpty, "Local provider returned no suggestions")
            XCTAssertTrue(suggestions.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } catch AIServiceError.localModelUnavailable(let reason) {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(
                AIServiceError.localModelUnavailable(reason: reason)
                    .localizedDescription
                    .hasPrefix("On-device model unavailable: ")
            )
        }
    }
}
