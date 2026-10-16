package com.rhymeai.app.ui.components

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ScribbleMotionTest {
    private val writeMillis = ScribbleMotion.WRITE_MILLIS.toLong()
    private val firstLineMillis = (ScribbleMotion.WRITE_MILLIS * ScribbleMotion.FIRST_LINE_SHARE).toLong()

    @Test
    fun `a loop starts on a blank card`() {
        assertEquals(0f to 0f, ScribbleMotion.lines(0))
    }

    @Test
    fun `the first line is written before the second starts`() {
        val (first, second) = ScribbleMotion.lines(firstLineMillis / 2)
        assertTrue(first in 0.45f..0.55f, "first line half written, was $first")
        assertEquals(0f, second)

        val (firstDone, secondStart) = ScribbleMotion.lines(firstLineMillis)
        assertTrue(firstDone > 0.99f, "first line finished, was $firstDone")
        assertTrue(secondStart < 0.01f, "second line barely started, was $secondStart")
    }

    @Test
    fun `both lines are drawn at the end of the write and through the hold`() {
        assertEquals(1f to 1f, ScribbleMotion.lines(writeMillis))
        assertEquals(1f to 1f, ScribbleMotion.lines(writeMillis + ScribbleMotion.HOLD_MILLIS / 2))
    }

    @Test
    fun `the loop wipes the card and starts again after the hold`() {
        assertEquals(0f to 0f, ScribbleMotion.lines(ScribbleMotion.PERIOD_MILLIS.toLong()))
        assertEquals(ScribbleMotion.lines(200), ScribbleMotion.lines(ScribbleMotion.PERIOD_MILLIS + 200L))
    }

    @Test
    fun `the static frame has the first line drawn and the second part way`() {
        val (first, second) = ScribbleMotion.STATIC_LINES
        assertEquals(1f, first)
        assertTrue(second in 0.1f..0.9f)
    }

    @Test
    fun `the wave is the UnBlock underline, spanning the full unit width`() {
        assertEquals(0f, ScribbleMotion.wave.first().first)
        assertEquals(1f, ScribbleMotion.wave.last().first)
        assertTrue(ScribbleMotion.wave.all { (_, y) -> y in 0f..1f })
    }
}
