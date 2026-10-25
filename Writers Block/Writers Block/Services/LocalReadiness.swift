import Combine
import Foundation
import FoundationModels

@MainActor
final class LocalInferenceStatus: ObservableObject {
    static let shared = LocalInferenceStatus()
    @Published private(set) var loadingCount = 0

    func beginLoading() { loadingCount += 1 }
    func endLoading() { loadingCount -= 1 }

}

struct LocalReadiness {
    let title: String
    let detail: String
    let canGenerate: Bool

    @MainActor static func current() -> LocalReadiness {
        #if DEBUG
        // UI tests and simulator QA answer suggestions from a scripted stream.
        if UITestFlags.scriptedSuggestionsEnabled() {
            return LocalReadiness(title: "Ready", detail: "Scripted suggestions · UI test", canGenerate: true)
        }
        #endif
        if AIService.shouldUseGemma() {
            return LocalReadiness(title: "Ready", detail: "Gemma · on this device", canGenerate: true)
        }
        if AIService.gemmaChoiceCleared() {
            return LocalReadiness(title: "Choose a model", detail: "Download a local model to use UnBlock on this device.", canGenerate: false)
        }
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return LocalReadiness(title: "Ready", detail: "Apple Intelligence · on this device", canGenerate: true)
            case .unavailable(.modelNotReady):
                return LocalReadiness(title: "Loading model", detail: "Apple Intelligence is preparing its model. You can keep writing.", canGenerate: false)
            case .unavailable(.appleIntelligenceNotEnabled):
                return LocalReadiness(title: "Choose a model", detail: "Download Gemma or enable Apple Intelligence in system settings.", canGenerate: false)
            default:
                break
            }
        }
        return LocalReadiness(title: "Choose a model", detail: "Download a local model to use UnBlock on this device.", canGenerate: false)
    }
}
