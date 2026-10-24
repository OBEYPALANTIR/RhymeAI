package com.rhymeai.app.util

object LyricTokenizer {
    /** Straight, typographic (U+2019) and modifier-letter (U+02BC) apostrophes all keep a contraction whole. */
    const val APOSTROPHES = "'\u2019\u02BC"
    val wordPattern = Regex("[a-zA-Z$APOSTROPHES]+")
    val alphanumericWordPattern = Regex("[a-zA-Z0-9$APOSTROPHES]+")
}
