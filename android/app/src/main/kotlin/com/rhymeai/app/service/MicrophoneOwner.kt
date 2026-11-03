package com.rhymeai.app.service

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * One recorder holds the microphone at a time, from the moment it starts opening it until it
 * has stopped: song memos and one liners never record together, even when both start at once.
 * The owner is the recorder instance itself, so one recorder can never release another's claim.
 */
object MicrophoneOwner {
    /** Snapshot state, so a sheet waiting on another recorder's claim recomposes when it is released. */
    var current: Any? by mutableStateOf(null)
        private set

    /** False when another recorder holds the microphone. */
    @Synchronized
    fun claim(owner: Any): Boolean {
        if (current != null && current !== owner) return false
        current = owner
        return true
    }

    /**
     * Claims for [owner] while [start] opens the microphone; any throw from [start] releases
     * the claim. Null (and [start] never runs) when another recorder holds the microphone.
     */
    inline fun <T : Any> claimWhileStarting(owner: Any, start: () -> T): T? {
        if (!claim(owner)) return null
        return try {
            start()
        } catch (error: Throwable) {
            release(owner)
            throw error
        }
    }

    @Synchronized
    fun release(owner: Any) {
        if (current === owner) current = null
    }
}
