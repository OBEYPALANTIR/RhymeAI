import ActivityKit
import Foundation

/// The Live Activity for one take: started with the recording, updated at most
/// every `minimumInterval` with the transcript and levels, ended with how the take finished.
final class OneLinerLiveActivity {
    typealias Phase = OneLinerActivityAttributes.ContentState.Phase

    static let minimumInterval: Duration = .milliseconds(250)
    /// ActivityKit refuses content over 4 KB; the capture keeps the whole transcript.
    static let transcriptLimit = 600
    /// How long an ended activity shows its outcome before the system removes it.
    static let endedDisplayTime: TimeInterval = 4

    private var activity: Activity<OneLinerActivityAttributes>?
    private var state = OneLinerActivityAttributes.ContentState(phase: .recording, transcript: "", levels: [])
    private var lastSent: ContinuousClock.Instant?
    /// An update held back by the interval; it sends whatever the state is when it fires.
    private var heldUpdate: Task<Void, Never>?
    /// The activity a Stop ended as "the take is waiting", and what it shows, so a
    /// discard or save that follows can correct its outcome while it is still up.
    private var stopped: (activity: Activity<OneLinerActivityAttributes>, state: OneLinerActivityAttributes.ContentState)?

    func start(startedAt: Date, levels: [Float]) {
        stopped = nil
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        state = Self.contentState(phase: .recording, transcript: "", levels: levels)
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
        state = Self.contentState(phase: .recording, transcript: transcript, levels: levels)
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
        guard let activity else { return correctStopped(to: phase) }
        self.activity = nil
        var final = state
        final.phase = phase
        final.levels = []
        stopped = phase == .stopped ? (activity, final) : nil
        Self.end(activity, showing: final)
    }

    /// A take Stop left waiting was then discarded or saved: the ended activity says so.
    private func correctStopped(to phase: Phase) {
        guard let stopped, phase != .stopped else { return }
        self.stopped = nil
        var final = stopped.state
        final.phase = phase
        Self.end(stopped.activity, showing: final)
    }

    /// Ending an ended activity again replaces its final content and dismissal time.
    private static func end(_ activity: Activity<OneLinerActivityAttributes>, showing final: OneLinerActivityAttributes.ContentState) {
        let dismissal = ActivityUIDismissalPolicy.after(Date().addingTimeInterval(endedDisplayTime))
        Task {
            guard activity.activityState != .dismissed else { return }
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: dismissal)
        }
    }

    private func send() {
        guard let activity else { return }
        lastSent = .now
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    /// The end of the transcript within `transcriptLimit` UTF-8 bytes, and levels to two places.
    static func contentState(phase: Phase, transcript: String, levels: [Float]) -> OneLinerActivityAttributes.ContentState {
        var tail = transcript.suffix(transcriptLimit)
        while tail.utf8.count > transcriptLimit { tail = tail.dropFirst() }
        let preview = tail.count < transcript.count ? "…" + tail : String(tail)
        return .init(phase: phase, transcript: preview, levels: levels.map { (Double($0) * 100).rounded() / 100 })
    }

    /// How long the next update waits so updates go at most once per `minimumInterval`.
    static func delay(since last: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration {
        guard let last else { return .zero }
        return max(.zero, minimumInterval - (now - last))
    }
}
