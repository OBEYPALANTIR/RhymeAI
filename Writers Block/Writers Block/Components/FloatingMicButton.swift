import AVFoundation
import SwiftUI

// Floating mic button that lives LEFT of the UnBlock FAB in EditorView.
//
// Idle state:  circular mic icon (matches the FAB's corner radius family).
// Recording:   morphs into a wider pill showing a live spectralizer
//              (12 amplitude bars), elapsed time, and a stop affordance.
//
// All layout is self-contained so EditorView's assistantFloatingButton
// can simply embed this view without knowing about recording state.
struct FloatingMicButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Service is owned by EditorViewModel; passed in rather than re-observed
    // via EnvironmentObject so the component stays reusable in previews.
    let service: VoiceMemoService
    /// Resolved at record time: a recording may be the first artifact of a
    /// song, so the project is created on demand rather than required up front.
    let ensureProjectId: () -> String

    // Bar count must be constant for the wave animation. 12 looks balanced
    // without overwhelming the narrow pill width.
    private static let barCount = 12

    // Phase offsets give each bar an independent animation cycle so the wave
    // effect never looks fully correlated. Values between 0 and π give gentle
    // asynchrony without visible synchronisation artifacts.
    private let barPhases: [Double] = (0..<FloatingMicButton.barCount).map { i in
        Double(i) * (.pi / Double(FloatingMicButton.barCount - 1))
    }

    var body: some View {
        Group {
            if service.isRecording {
                spectralPill
            } else {
                idleMicButton
            }
        }
        .rhymeAnimation(.easeInOut(duration: 0.25), value: service.isRecording)
    }

    // MARK: - Idle

    private var idleMicButton: some View {
        Button {
            let projectId = ensureProjectId()
            Task { await service.startRecording(projectId: projectId) }
        } label: {
            Image(systemName: "mic.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(
                    width: RhymeAITokens.Touch.comfortable,
                    height: RhymeAITokens.Touch.comfortable
                )
                .liquidGlassSurface(
                    cornerRadius: RhymeAITokens.Radius.pill,
                    tint: .indigo,
                    interactive: true,
                    fallbackOpacity: 0.35
                )
                .shadow(
                    color: .indigo.opacity(0.22),
                    radius: RhymeAITokens.Spacing.sm,
                    y: RhymeAITokens.Spacing.xxs
                )
        }
        .accessibilityLabel("Record voice memo")
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

    // MARK: - Recording Spectralizer Pill

    private var spectralPill: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            // Live amplitude bars
            spectralBars

            // Elapsed time — MM:SS
            Text(formattedElapsed)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .monospacedDigit()

            // Stop button
            Button {
                service.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(
                        width: RhymeAITokens.Touch.minimum,
                        height: RhymeAITokens.Touch.minimum
                    )
                    .background(.red.opacity(0.85), in: Circle())
            }
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .padding(.vertical, RhymeAITokens.Spacing.xs)
        .liquidGlassSurface(
            cornerRadius: RhymeAITokens.Radius.pill,
            tint: .indigo,
            interactive: false,
            fallbackOpacity: 0.35
        )
        .shadow(
            color: .indigo.opacity(0.22),
            radius: RhymeAITokens.Spacing.sm,
            y: RhymeAITokens.Spacing.xxs
        )
        .transition(.scale(scale: 0.88, anchor: .trailing).combined(with: .opacity))
    }

    // MARK: - Bar Cluster

    private var spectralBars: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                SpectralBar(
                    normalizedAmplitude: service.averagePowerNormalized,
                    phaseOffset: barPhases[index],
                    reduceMotion: reduceMotion
                )
            }
        }
        .frame(height: 18)
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        let total = Int(service.recordingElapsed)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Single Spectral Bar

// Each bar derives its height from the global normalised amplitude plus a
// per-bar phase offset. The offset spreads the visual energy so bars at
// different positions peak at slightly different moments, creating a wave
// effect even on a steady signal.
private struct SpectralBar: View {
    let normalizedAmplitude: Float
    let phaseOffset: Double
    let reduceMotion: Bool

    // Minimum bar height keeps all bars visible at silence; maximum caps the
    // bar at the container height (18 pt) with a small inset for breathing room.
    private static let minHeight: CGFloat = 2
    private static let maxHeight: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white.opacity(0.9))
            .frame(width: 2, height: barHeight)
            .rhymeAnimation(reduceMotion ? .none : .easeOut(duration: 0.1), value: barHeight)
    }

    private var barHeight: CGFloat {
        // Perturb each bar's amplitude with a sine wave keyed on the phase offset
        // so neighbouring bars peak at different times. The perturbation scale
        // (0.15) is modest enough that all bars remain clearly data-driven rather
        // than decorative.
        let perturb = Float(sin(phaseOffset + Double(normalizedAmplitude) * .pi)) * 0.15
        let scaled = max(0, min(1, normalizedAmplitude + perturb))
        return Self.minHeight + CGFloat(scaled) * (Self.maxHeight - Self.minHeight)
    }
}
