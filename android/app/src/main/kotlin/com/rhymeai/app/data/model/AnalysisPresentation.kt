package com.rhymeai.app.data.model

enum class AnalysisPresentation(val storageValue: String, val displayName: String) {
    COLOR("color", "Color"),
    INK_MARKS("ink_marks", "Ink Marks");

    companion object {
        fun fromStorage(value: String?): AnalysisPresentation =
            entries.firstOrNull { it.storageValue == value } ?: COLOR
    }
}
