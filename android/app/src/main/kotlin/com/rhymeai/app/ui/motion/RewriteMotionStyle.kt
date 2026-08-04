package com.rhymeai.app.ui.motion

enum class RewriteMotionStyle(val buildValue: String) {
    PENCIL("pencil"),
    RIPPLE("ripple"),
    PAPER("paper");

    companion object {
        fun fromBuildValue(value: String): RewriteMotionStyle =
            entries.firstOrNull { it.buildValue == value }
                ?: throw IllegalArgumentException("Unknown rewrite motion style: $value")
    }
}
