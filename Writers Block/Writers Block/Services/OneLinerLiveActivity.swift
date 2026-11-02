import ActivityKit
import Foundation

/// The Live Activity for one take: started with the recording, updated at most
/// every `minimumInterval` with the transcript and levels, ended with how the take finished.
final class OneLinerLiveActivity {
    typealias Phase = OneLinerActivityAttributes.ContentState.Phase

    static let minimumInterval: Duration = .milliseconds(250)
    /// How long an ended activity shows its outcome before the system removes it.
    static let endedDisplayTime: TimeInterval = 4

    private var activity: Activity<OneLinerActivityAttributes>?
    private var state = OneLinerActivityAttributes.ContentState(phase: .recording, transcript: "", levels: [])
    private var lastSent: ContinuousClock.Instant?
    /// An update held back by the interval; it sends whatever the state is when it fires.
    private var heldUpdate: Task<Void, Never>?

    func start(startedAt: Date, levels: [Float]) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        state = .init(phase: .recording, transcript: "", levels: levels.map(Double.init))
        let attributes = OneLinerActivityAttributes(
            startedAt: startedAt,
            appearance: AppAppearanceStyle.resolve(UserDefaults.standard.string(forKey: AppAppearanceStyle.storageKey)).rawValue
        )
        // No activity (turned off, or the system refused) only means no Lock Screen view.
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
        lastSent = .now
    }

    func update(transcript: String, levels: [Float]) {
        guard activity != nil else { return }
        state.transcript = transcript
        state.levels = levels.map(Double.init)
        guard heldUpdate == nil else { return }
        let wait = Self.delay(since: lastSent, now: .now)
        guard wait > .zero else { return send() }
        heldUpdate = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.heldUpdate = nil
            self.send()
        }
    }

    func end(_ phase: Phase) {
        heldUpdate?.cancel()
        heldUpdate = nil
        guard let activity else { return }
        self.activity = nil
        var final = state
        final.phase = phase
        final.levels = []
        let dismissal = ActivityUIDismissalPolicy.after(Date().addingTimeInterval(Self.endedDisplayTime))
        Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: dismissal) }
    }

    private func send() {
        guard let activity else { return }
        lastSent = .now
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    /// How long the next update waits so updates go at most once per `minimumInterval`.
    static func delay(since last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration {
        guard let last else { return .zero }
        return max(.zero, minimumInterval - (now - last))
    }
}
