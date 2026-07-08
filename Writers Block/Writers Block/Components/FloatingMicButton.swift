import AVFoundation
import SwiftUI

// Floating mic button that lives LEFT of the UnBlock FAB in EditorView.
//
// IDLE STATE  — circular mic icon (56 pt, matches pill corner-radius family).
//
// ON RECORD PRESS — single animatable `progress` (0 → 1) drives everything
// in one spring so nothing can desync:
//   • Pill width:    comfortable (56) → recordingPillWidth (~220 pt)
//   • Glyph:        mic.fill crossfades to pause.fill (kept as stop semantics)
//   • Bars / timer: stagger-fade in once progress > 0.6
//
// ON STOP PRESS — progress reverses (1 → 0), bars/timer stagger out first,
// then pill contracts back to circle, glyph reverts.
//
// `accessibilityReduceMotion` collapses all transitions to instant swaps.
//
// The UnBlock FAB fall-down / rise-up is orchestrated by EditorView, which
// observes `service.isRecording` directly. This component stays self-contained.
struct FloatingMicButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let service: VoiceMemoService
    /// Called at record time to obtain (or lazily create) the project for this recording.
    let ensureProjectId: () -> String

    // MARK: - Animation state

    // Single progress value: 0 = fully idle, 1 = fully recording.
    // Driven by `service.isRecording` via onChange below.
    @State private var progress: CGFloat = 0

    // Bar history is a scrolling level meter: newest sample lives at the right edge.
    private static let barCount = 22
    @State private var barHistory: [Float] = Array(
        repeating: 0,
        count: FloatingMicButton.barCount
    )

    // MARK: - Layout constants

    // Idle circle diameter — matches Touch.comfortable token.
    private let idleSize: CGFloat = RhymeAITokens.Touch.comfortable          // 56
    // Recording pill total width — wide enough to hold bars + timer + stop button
    // and for its right edge to align with where UnBlock's right edge was before
    // it fell away. Tuned to roughly match UnBlock's footprint (~210 pt).
    private let recordingPillWidth: CGFloat = 220
    // Height stays constant — same as the idle circle.
    private let pillHeight: CGFloat = RhymeAITokens.Touch.comfortable         // 56
    // Right-side glyph slot: 44 pt touch target + 8 pt trailing padding.
    private let glyphSlot: CGFloat = RhymeAITokens.Touch.minimum + RhymeAITokens.Spacing.xs

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .trailing) {
            // Background pill / circle — width interpolates with progress.
            Color.clear
                .frame(width: interpolatedWidth, height: pillHeight)
                .liquidGlassSurface(
                    cornerRadius: RhymeAITokens.Radius.pill,
                    tint: .indigo,
                    interactive: progress < 0.5,
                    fallbackOpacity: 0.35
                )
                .shadow(
                    color: .indigo.opacity(0.22),
                    radius: RhymeAITokens.Spacing.sm,
                    y: RhymeAITokens.Spacing.xxs
                )

            // Content layer: idle glyph on the right, recording controls
            // growing leftward. Both are pinned to the trailing edge so the
            // pill expands left while the stop button stays where it always was.
            HStack(spacing: 0) {
                // Recording region — spectralizer + timer
                // Fades in once the pill is mostly stretched (progress > 0.55).
                if progress > 0.01 {
                    HStack(spacing: RhymeAITokens.Spacing.xs) {
                        spectralBars
                        Text(formattedElapsed)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .padding(.leading, RhymeAITokens.Spacing.sm)
                    .opacity(recordingContentOpacity)
                    .frame(width: max(0, interpolatedWidth - glyphSlot), alignment: .leading)
                    .transition(.opacity)
                }

                Spacer(minLength: 0)

                // Central glyph — mic crossfades to pause as progress advances.
                // Wrapped in a button: when idle it starts recording; when
                // recording the entire control is the stop affordance.
                Button {
                    if service.isRecording {
                        service.stopRecording()
                    } else {
                        let projectId = ensureProjectId()
                        Task { await service.startRecording(projectId: projectId) }
                    }
                } label: {
                    ZStack {
                        // Idle mic glyph
                        Image(systemName: "mic.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .opacity(Double(max(0, 1 - progress * 2.5)))
                            .scaleEffect(max(0.6, 1 - Double(progress) * 0.4))

                        // Recording pause glyph (pause per design spec; action stops + saves)
                        Image(systemName: "pause.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .opacity(Double(max(0, progress * 2.5 - 1.5)))
                            .scaleEffect(max(0.6, Double(progress) * 0.9 + 0.1))
                            .background(
                                Circle()
                                    .fill(.red.opacity(min(0.85, Double(progress))))
                                    .frame(
                                        width: RhymeAITokens.Touch.minimum,
                                        height: RhymeAITokens.Touch.minimum
                                    )
                            )
                    }
                    .frame(
                        width: RhymeAITokens.Touch.minimum,
                        height: RhymeAITokens.Touch.minimum
                    )
                }
                .accessibilityLabel(service.isRecording ? "Stop recording" : "Record voice memo")
                .padding(.trailing, RhymeAITokens.Spacing.xs)
            }
            .frame(width: interpolatedWidth, height: pillHeight)
        }
        // Accessibility identifiers are set by EditorView on the parent container.
        .frame(width: interpolatedWidth, height: pillHeight)
        // React to service state changes with a spring animation.
        .onChange(of: service.isRecording) { _, isRecording in
            withAnimation(reduceMotion ? nil : RhymeAITokens.Motion.expressive) {
                progress = isRecording ? 1 : 0
            }
        }
        .task(id: service.isRecording) {
            guard service.isRecording else {
                barHistory = Array(repeating: 0, count: Self.barCount)
                return
            }

            while service.isRecording && !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    break
                }

                guard service.isRecording && !Task.isCancelled else { break }
                var next = barHistory
                next.removeFirst()
                next.append(service.averagePowerNormalized)
                barHistory = next
            }
        }
        // Permission denied alert lives here so the mic button is self-contained.
        .alert("Microphone Access Denied", isPresented: Bindable(service).permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access in Settings to record melody ideas.")
        }
    }

    // MARK: - Interpolated layout

    private var interpolatedWidth: CGFloat {
        idleSize + (recordingPillWidth - idleSize) * progress
    }

    // Recording content (bars + timer) fades in after the pill is ~60% stretched.
    private var recordingContentOpacity: Double {
        let fadeStart = 0.55
        let fadeEnd   = 0.85
        return max(0, min(1, (Double(progress) - fadeStart) / (fadeEnd - fadeStart)))
    }

    // MARK: - Spectral bars

    private var spectralBars: some View {
        Canvas { ctx, size in
            let n = barHistory.count
            guard n > 0, size.width > 0 else { return }

            let pitch = size.width / CGFloat(n)
            let barW = pitch * 0.6

            for (i, sample) in barHistory.enumerated() {
                let h = max(2, CGFloat(sample) * size.height)
                let x = CGFloat(i) * pitch + (pitch - barW) / 2
                let rect = CGRect(
                    x: x,
                    y: (size.height - h) / 2,
                    width: barW,
                    height: h
                )
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: barW / 2),
                    with: .color(.white.opacity(0.9))
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
    }

    // MARK: - Time formatter

    private var formattedElapsed: String {
        let total = Int(service.recordingElapsed)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
