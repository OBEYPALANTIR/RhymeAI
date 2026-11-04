package com.rhymeai.app.data.model

/** Which edge the floating chrome (UnBlock + mic, One Liners Record + Type) sits on. */
enum class DominantHand(val storageValue: String, val displayName: String) {
    RIGHT("right", "Right"),
    LEFT("left", "Left");

    companion object {
        fun fromStorage(value: String?): DominantHand =
            entries.firstOrNull { it.storageValue == value } ?: RIGHT
    }
}
