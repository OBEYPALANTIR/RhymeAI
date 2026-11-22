import Foundation

enum AIErrorRecoveryAction: Equatable {
    case openSettings
    /// No on-device model is set up, so retrying cannot succeed.
    case setUpModel
    case retry

    init(errorMessage: String) {
        let normalizedMessage = errorMessage.lowercased()
        if AIService.noModelReasons.contains(where: { normalizedMessage.contains($0.lowercased()) }) {
            self = .setUpModel
        } else if normalizedMessage.contains("no api key set")
            || normalizedMessage.contains("check your api key in settings")
            || normalizedMessage.contains("choose a cloud provider in settings") {
            self = .openSettings
        } else {
            self = .retry
        }
    }
}
