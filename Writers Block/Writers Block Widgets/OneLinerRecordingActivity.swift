import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity while a one liner records: timer, level bars that follow the
/// meter, the live transcript and Done. System motion only.
struct OneLinerRecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OneLinerActivityAttributes.self) { context in
            let palette = AppAppearanceStyle.resolve(context.attributes.appearance).palette
            OneLinerActivityBanner(context: context, palette: palette)
                .activityBackgroundTint(palette.surface)
                .activitySystemActionForegroundColor(palette.primaryInk)
        } dynamicIsland: { context in
            // The island is always dark, so it takes Graphite's ink.
            let palette = AppAppearanceStyle.graphite.palette
            let recording = context.state.phase == .recording
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OneLinerActivityGlyph(phase: context.state.phase, palette: palette)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if recording {
                        OneLinerActivityTimer(startedAt: context.attributes.startedAt)
                            .foregroundStyle(palette.secondaryInk)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        OneLinerActivityBody(state: context.state, palette: palette)
                    }
                }
            } compactLeading: {
                OneLinerActivityGlyph(phase: context.state.phase, palette: palette)
            } compactTrailing: {
                if recording {
                    OneLinerActivityTimer(startedAt: context.attributes.startedAt)
                        .foregroundStyle(palette.secondaryInk)
                } else {
                    Text(OneLinerActivityBody.outcome(context.state.phase).short)
                        .font(.caption2.weight(.semibold))
                }
            } minimal: {
                OneLinerActivityGlyph(phase: context.state.phase, palette: palette)
            }
        }
    }
}

private struct OneLinerActivityBanner: View {
    let context: ActivityViewContext<OneLinerActivityAttributes>
    let palette: AppAppearancePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                Text("WB")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.canvas)
                    .frame(width: 34, height: 34)
                    .background(palette.primaryInk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text("Writers Block · One Liner")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if context.state.phase == .recording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(palette.recording)
                            .frame(width: 8, height: 8)
                        OneLinerActivityTimer(startedAt: context.attributes.startedAt)
                            .foregroundStyle(palette.secondaryInk)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Recording")
                }
            }
            OneLinerActivityBody(state: context.state, palette: palette)
        }
        .padding(21)
        .foregroundStyle(palette.primaryInk)
    }
}

/// Bars, transcript and Done while recording; the outcome once it ends.
private struct OneLinerActivityBody: View {
    let state: OneLinerActivityAttributes.ContentState
    let palette: AppAppearancePalette

    var body: some View {
        if state.phase == .recording {
            HStack(spacing: 3) {
                ForEach(Array(state.levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(index == state.levels.count - 1 ? palette.primaryInk : palette.secondaryInk)
                        .frame(width: 3, height: max(5, CGFloat(level) * 34))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .accessibilityHidden(true)
            Text(state.transcript.isEmpty ? "Listening…" : state.transcript)
                .font(.system(size: 17))
                .lineLimit(3)
                .foregroundStyle(state.transcript.isEmpty ? palette.secondaryInk : palette.primaryInk)
            HStack(spacing: 13) {
                Text("Live transcript. Audio is kept too.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(intent: StopOneLinerRecordingIntent()) {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 21)
                        .frame(height: 44)
                        .foregroundStyle(palette.onAction)
                        .background(palette.action, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done, save the one liner")
            }
        } else {
            let outcome = Self.outcome(state.phase)
            Label(outcome.long, systemImage: outcome.systemImage)
                .font(.system(size: 15, weight: .semibold))
            if !state.transcript.isEmpty {
                Text(state.transcript)
                    .font(.system(size: 15))
                    .lineLimit(2)
                    .foregroundStyle(palette.secondaryInk)
            }
        }
    }

    static func outcome(_ phase: OneLinerActivityAttributes.ContentState.Phase) -> (short: String, long: String, systemImage: String) {
        switch phase {
        case .recording: ("Rec", "Recording", "mic.fill")
        case .saved: ("Saved", "Saved to One Liners", "checkmark")
        case .discarded: ("Gone", "Discarded", "xmark")
        case .stopped: ("Kept", "Stopped. The take is waiting in Writers Block.", "pause.fill")
        }
    }
}

private struct OneLinerActivityGlyph: View {
    let phase: OneLinerActivityAttributes.ContentState.Phase
    let palette: AppAppearancePalette

    var body: some View {
        Image(systemName: phase == .recording ? "mic.fill" : OneLinerActivityBody.outcome(phase).systemImage)
            .foregroundStyle(phase == .recording ? palette.recording : palette.primaryInk)
            .accessibilityLabel(OneLinerActivityBody.outcome(phase).long)
    }
}

/// Counts up from the take's start; the system redraws it, so no update is needed per second.
private struct OneLinerActivityTimer: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            .font(.system(size: 13).monospacedDigit())
            .monospaced()
            .multilineTextAlignment(.trailing)
            .frame(width: 40, alignment: .trailing)
    }
}

#Preview("Recording", as: .content, using: OneLinerActivityAttributes(startedAt: .now, appearance: "graphite")) {
    OneLinerRecordingActivity()
} contentStates: {
    OneLinerActivityAttributes.ContentState(
        phase: .recording,
        transcript: "Found the Lord in a gas station bathroom",
        levels: [0.2, 0.4, 0.6, 1, 0.6, 0.4, 0.2, 0.4, 0.6, 1, 0.6, 0.2]
    )
    OneLinerActivityAttributes.ContentState(phase: .saved, transcript: "Found the Lord in a gas station bathroom", levels: [])
}
