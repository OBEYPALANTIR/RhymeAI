package com.rhymeai.app

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The scripted suggestion stream behind the debug `SCRIPTED_SUGGESTIONS` extra:
 * UI tests and emulator QA rely on it delivering the same lines, in order, every time.
 */
class ScriptedSuggestionStreamTest {
    private fun collect(count: Int): List<SuggestedLine> = runBlocking {
        ScriptedSuggestionStream(holdMillis = 0, intervalMillis = 0, count = count).lines().toList()
    }

    @Test
    fun deliversTheRequestedLinesInOrder() {
        val lines = collect(count = 4)

        assertEquals(ScriptedSuggestionStream.LINES.take(4), lines.map { it.text })
        assertTrue(lines.all { it.rhymeTier == 0 && !it.isHook }, "scripted lines carry no rhyme verdict")
    }

    @Test
    fun zeroLinesExercisesTheEmptyAnswer() {
        assertTrue(collect(count = 0).isEmpty())
    }

    @Test
    fun countIsClampedToTheScriptedLines() {
        assertEquals(ScriptedSuggestionStream.LINES, collect(count = 99).map { it.text })
        assertTrue(collect(count = -2).isEmpty())
    }

    @Test
    fun theFourthLineRunsLongEnoughToWrap() {
        assertEquals(6, ScriptedSuggestionStream.LINES.size)
        assertTrue(ScriptedSuggestionStream.LINES[3].length > 60)
    }
}
