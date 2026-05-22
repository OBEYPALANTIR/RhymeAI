package com.rhymeai.app.util

object RhymePhonetics {
    fun rhymeKeys(word: String, maxDepth: Int = 2): List<String> {
        return ProsodyAnalyzer.rhymeKeys(word, maxDepth)
    }
}
