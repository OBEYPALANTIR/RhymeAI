package com.rhymeai.app.data.model

enum class AppAppearance(
    val storageValue: String,
    val displayName: String
) {
    INK("ink", "Ink"),
    PAPER("paper", "Paper"),
    GRAPHITE("graphite", "Graphite");

    val isDark: Boolean
        get() = this == GRAPHITE

    companion object {
        fun fromStorage(value: String?): AppAppearance =
            entries.firstOrNull { it.storageValue == value } ?: INK
    }
}
