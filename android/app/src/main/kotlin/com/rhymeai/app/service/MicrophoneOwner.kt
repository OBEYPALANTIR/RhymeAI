package com.rhymeai.app.service

/**
 * One recorder holds the microphone at a time, from the moment it starts opening it until it
 * has stopped: song memos and one liners never record together, even when both start at once.
 * The owner is the recorder instance itself, so one recorder can never release another's claim.
 */
object MicrophoneOwner {
    @Volatile var current: Any? = null
        private set

    /** False when another recorder holds the microphone. */
    @Synchronized
    fun claim(owner: Any): Boolean {
        if (current != null && current !== owner) return false
        current = owner
        return true
    }

    @Synchronized
    fun release(owner: Any) {
        if (current === owner) current = null
    }
}
