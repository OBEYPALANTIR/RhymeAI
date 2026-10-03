package com.rhymeai.app.service

internal data class SyntheticGenerationCapture(
    val runId: String,
    val expectedPromptSha256: String,
    val seed: Int,
    val onNativeChunk: (String, Long) -> Unit,
    val onParserChunk: (String, Long) -> Unit,
    val onGenerationStarted: (Long) -> Unit = {}
)

/** Observes native callback arrival independently of relay and parser consumption. */
internal class SyntheticNativeCaptureGate {
    private data class Active(val capture: SyntheticGenerationCapture, val startedAtNs: Long)
    private val lock = Any()
    @Volatile private var active: Active? = null

    fun begin(capture: SyntheticGenerationCapture, startedAtNs: Long) = synchronized(lock) {
        check(active == null) { "Synthetic native capture already active" }
        active = Active(capture, startedAtNs)
    }

    fun recordNativeCallback(chunk: String, arrivedAtNs: Long) {
        if (active == null) return
        synchronized(lock) {
            active?.let { it.capture.onNativeChunk(chunk, arrivedAtNs - it.startedAtNs) }
        }
    }

    fun finish() = synchronized(lock) { active = null }
}
