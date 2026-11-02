package com.rhymeai.app.service

/**
 * One recorder holds the microphone at a time, from the moment it starts opening it until it
 * has stopped: a song memo and a one liner can never record together, even when both start
 * at once.
 */
object MicrophoneOwner {
    enum class Owner { SONG_MEMO, ONE_LINER }

    @Volatile var current: Owner? = null
        private set

    /** False when the other recorder holds the microphone. */
    @Synchronized
    fun claim(owner: Owner): Boolean {
        if (current != null && current != owner) return false
        current = owner
        return true
    }

    @Synchronized
    fun release(owner: Owner) {
        if (current == owner) current = null
    }
}
