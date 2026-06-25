package com.rhymeai.app.util

object LyricTokenizer {
    val wordPattern = Regex("[a-zA-Z']+")
    val alphanumericWordPattern = Regex("[a-zA-Z0-9']+")
}
