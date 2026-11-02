import ActivityKit
import Foundation

/// The Live Activity shown while a one liner is recorded.
// Encoded and read off the main actor by ActivityKit.
nonisolated struct OneLinerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording
            case saved
            case discarded
            /// Recording ended (the app left the foreground, an interruption, or Stop)
            /// with the take still waiting in the capture sheet.
            case stopped
        }

        var phase: Phase
        var transcript: String
        /// Recent input levels 0...1, oldest first, as the capture sheet's bars.
        var levels: [Double]
    }

    var startedAt: Date
    /// The app's `AppAppearanceStyle` raw value when the take started.
    var appearance: String

    /// Ends every one-liner activity at once, for a Done with nothing recording.
    static func endAll() async {
        for activity in Activity<Self>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
