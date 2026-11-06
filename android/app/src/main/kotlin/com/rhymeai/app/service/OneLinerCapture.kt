package com.rhymeai.app.service

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.rhymeai.app.data.model.OneLiner
import com.rhymeai.app.data.repository.OneLinerSaveFailure
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

const val FINISH_ONE_LINER_FIRST = "Finish this one liner first. Save it or close it, then try again."
const val SAVE_FAILED_NOTICE = "Couldn't save this line. It's still here, so try again."

/** One open capture sheet: its words, its take and its save outlive the sheet's composition. */
class OneLinerCaptureSession(val mode: Mode, val recorder: OneLinerRecorder = OneLinerRecorder()) {
    /** Record opens with the mic hot; Type and Edit open with the keyboard. */
    sealed interface Mode {
        data object Record : Mode
        data object Type : Mode
        data class Edit(val line: OneLiner) : Mode
    }

    var text by mutableStateOf((mode as? Mode.Edit)?.line?.text.orEmpty())
    /** The field's words when the current take started; the transcript follows them. */
    var textBeforeTake by mutableStateOf("")
    var saveError by mutableStateOf<String?>(null)
    var saving by mutableStateOf(false)
        internal set
    /** The transcript already put into [text], so a recreated sheet does not put it in twice. */
    var appliedTranscript = ""
    /** The opening action (mic or keyboard) already ran; a recreated sheet does not run it again. */
    var opened = false

    /** A take started: its transcript follows the words in the field now, and is applied afresh. */
    fun takeStarted() {
        textBeforeTake = text.trim()
        appliedTranscript = ""
    }

    /** Puts the take's transcript after the words typed before it, once per transcript. */
    fun applyTranscript(heard: String) {
        if (heard.isEmpty() || heard == appliedTranscript) return
        appliedTranscript = heard
        text = if (textBeforeTake.isEmpty()) heard else "$textBeforeTake $heard"
    }

    /** Drops a new capture's take so the writer can record again; the words stay. Never during a save, which holds the take. */
    fun discardTake() {
        if (saving || mode is Mode.Edit) return
        recorder.discard()
    }
}

/**
 * The capture the One Liners screen shows, held by the ViewModel (its [scope] is the
 * ViewModel's) so recreating the activity keeps the words, the take and a save in progress.
 * The sheet only observes it. Only an explicit close discards the take.
 */
class OneLinerCaptures(private val scope: CoroutineScope) {
    var current by mutableStateOf<OneLinerCaptureSession?>(null)
        private set

    /** False when a capture is already open: it is never replaced, and says so. */
    fun open(mode: OneLinerCaptureSession.Mode): Boolean {
        current?.let {
            it.recorder.notice = FINISH_ONE_LINER_FIRST
            return false
        }
        current = OneLinerCaptureSession(mode)
        return true
    }

    /** Closed without saving: the take is not kept. A save in progress finishes first. */
    fun dismiss() {
        val session = current ?: return
        if (session.saving) return
        session.recorder.discard()
        current = null
    }

    /**
     * Saves the open capture through [persist]. Success closes it; a failure keeps the
     * words and the take (from wherever the failed save left it) for another try.
     */
    fun save(persist: suspend (text: String, take: File?, durationMs: Long) -> Unit) {
        val session = current ?: return
        if (session.saving) return
        val recorder = session.recorder
        // The audio failed to write: stay open so the notice is read before saving words alone.
        // A start still opening the mic is cancelled; it has no take yet.
        if ((recorder.isRecording || recorder.isStarting) && !recorder.stop()) return
        if (session.text.isBlank() && (session.mode is OneLinerCaptureSession.Mode.Edit || recorder.takeFile == null)) return
        session.saving = true
        session.saveError = null
        scope.launch {
            try {
                persist(session.text.trim(), recorder.takeFile, recorder.takeDurationMs)
                if (current === session) current = null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                (error as? OneLinerSaveFailure)?.takeNowAt?.let(recorder::takeMoved)
                session.saveError = SAVE_FAILED_NOTICE
            } finally {
                session.saving = false
            }
        }
    }
}
