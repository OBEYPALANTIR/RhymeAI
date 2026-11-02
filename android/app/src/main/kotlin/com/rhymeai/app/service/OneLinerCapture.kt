package com.rhymeai.app.service

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.rhymeai.app.data.model.OneLiner
import java.io.File

const val FINISH_ONE_LINER_FIRST = "Finish this one liner first. Save it or close it, then try again."
const val RECOVERED_TAKE_NOTICE = "Your last take wasn't saved. It's here: save it, or close to let it go."

/** One open capture sheet: its words and its take outlive the sheet's composition. */
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
    /** The transcript already put into [text], so a recreated sheet does not put it in twice. */
    var appliedTranscript = ""
    /** The opening action (mic or keyboard) already ran; a recreated sheet does not run it again. */
    var opened = false
}

/**
 * The capture the One Liners screen shows, held by the ViewModel so recreating the activity
 * keeps the words and the take. Only an explicit close discards the take; a save just ends it.
 */
class OneLinerCaptures(private val leftoverTake: () -> File? = { null }) {
    var current by mutableStateOf<OneLinerCaptureSession?>(null)
        private set

    /** False when a capture is already open: it is never replaced, and says so. */
    fun open(mode: OneLinerCaptureSession.Mode): Boolean {
        current?.let {
            it.recorder.notice = FINISH_ONE_LINER_FIRST
            return false
        }
        val session = OneLinerCaptureSession(mode)
        // A finished take an earlier capture left (the app closed before Save) is offered again.
        if (mode !is OneLinerCaptureSession.Mode.Edit) leftoverTake()?.let {
            session.recorder.recover(it)
            session.recorder.notice = RECOVERED_TAKE_NOTICE
        }
        current = session
        return true
    }

    /** Closed without saving: the take is not kept. */
    fun dismiss() {
        current?.recorder?.discard()
        current = null
    }

    /** Saved: the take now belongs to its line. */
    fun saved() {
        current = null
    }
}
