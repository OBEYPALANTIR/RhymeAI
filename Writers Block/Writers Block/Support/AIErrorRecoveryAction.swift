import Foundation

enum AIErrorRecoveryAction: Equatable {
    case openSettings
    case retry

    init(errorMessage: String) {
        let normalizedMessage = errorMessage.lowercased()
        if normalizedMessage.contains("no api key set")
            || normalizedMessage.contains("check your api key in settings")
            || normalizedMessage.contains("choose a cloud provider in settings") {
            self = .openSettings
        } else {
            self = .retry
        }
    }
}
