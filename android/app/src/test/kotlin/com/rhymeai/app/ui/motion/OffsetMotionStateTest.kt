package com.rhymeai.app.ui.motion

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.BroadcastFrameClock
import com.rhymeai.app.ui.theme.DesignTokens
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OffsetMotionStateTest {
    private val animation = tween<Float>(durationMillis = 100, easing = LinearEasing)

    @Test
    fun `drag interrupts presentation and no later frame overwrites the finger position`() {
        val clock = BroadcastFrameClock()
        runBlocking(clock) {
            val motion = OffsetMotionState(this)
            motion.snapTo(100f)
            motion.animateTo(0f, animation, animationsEnabled = true)
            yield()
            clock.sendFrame(0L)
            yield()
            clock.sendFrame(50_000_000L)
            yield()
            assertTrue(motion.value > 0f && motion.value < 100f)

            motion.snapTo(70f)
            clock.sendFrame(200_000_000L)
            yield()
            assertEquals(70f, motion.value)
        }
    }

    @Test
    fun `new settle cancels close without firing the stale dismissal`() {
        val clock = BroadcastFrameClock()
        runBlocking(clock) {
            val motion = OffsetMotionState(this)
            var dismissed = false
            var settled = false
            motion.animateTo(100f, animation, animationsEnabled = true) { dismissed = true }
            yield()
            clock.sendFrame(0L)
            yield()
            clock.sendFrame(50_000_000L)
            yield()

            motion.animateTo(0f, animation, animationsEnabled = true) { settled = true }
            yield()
            clock.sendFrame(60_000_000L)
            yield()
            clock.sendFrame(200_000_000L)
            yield()
            assertFalse(dismissed)
            assertTrue(settled)
            assertEquals(0f, motion.value)
        }
    }

    @Test
    fun `release velocity toward the target carries the settle further on the first frames`() {
        fun valueAfter50ms(initialVelocity: Float): Float {
            val clock = BroadcastFrameClock()
            return runBlocking(clock) {
                val motion = OffsetMotionState(this)
                motion.snapTo(100f)
                motion.animateTo(0f, spring(), animationsEnabled = true, initialVelocity = initialVelocity)
                yield()
                clock.sendFrame(0L)
                yield()
                clock.sendFrame(50_000_000L)
                yield()
                motion.value.also { motion.snapTo(it) }
            }
        }
        val still = valueAfter50ms(0f)
        val flung = valueAfter50ms(-2_000f)
        assertTrue(flung < still - 5f, "flung=$flung still=$still")
    }

    @Test
    fun `reduced motion immediately completes sheet and recording offsets without frames`() = runBlocking {
        val motion = OffsetMotionState(this)
        for (target in listOf(800f, 0f, -64f, 0f)) {
            var completed = false
            motion.animateTo(target, animation, animationsEnabled = false) { completed = true }
            assertEquals(target, motion.value)
            assertTrue(completed)
        }
    }

    @Test
    fun `reduced motion replaces in flight animation and cancels its callback`() {
        val clock = BroadcastFrameClock()
        runBlocking(clock) {
            val motion = OffsetMotionState(this)
            var staleCompletion = false
            motion.animateTo(-64f, animation, animationsEnabled = true) { staleCompletion = true }
            yield()
            clock.sendFrame(0L)
            yield()
            motion.animateTo(0f, animation, animationsEnabled = false)
            clock.sendFrame(200_000_000L)
            yield()
            assertEquals(0f, motion.value)
            assertFalse(staleCompletion)
        }
    }

    @Test
    fun `stop at target ends a flung dismiss spring on arrival instead of overshooting`() {
        fun peakAndFinished(stopAtTarget: Boolean): Pair<Float, Boolean> {
            val clock = BroadcastFrameClock()
            return runBlocking(clock) {
                val motion = OffsetMotionState(this)
                var finished = false
                var peak = 0f
                motion.snapTo(400f)
                motion.animateTo(
                    3_000f,
                    DesignTokens.Motion.settleSpring(visibilityThreshold = 0.5f),
                    animationsEnabled = true,
                    initialVelocity = 3_000f,
                    stopAtTarget = stopAtTarget
                ) { finished = true }
                yield()
                var frame = 0L
                while (!finished && frame < 300) {
                    clock.sendFrame(frame++ * 16_000_000L)
                    yield()
                    peak = maxOf(peak, motion.value)
                }
                (peak to finished).also { motion.snapTo(motion.value) }
            }
        }
        val (boundedPeak, boundedFinished) = peakAndFinished(stopAtTarget = true)
        assertTrue(boundedFinished)
        assertEquals(3_000f, boundedPeak)
        val (freePeak, _) = peakAndFinished(stopAtTarget = false)
        assertTrue(freePeak > 3_000f, "the unbounded spring should overshoot: peak=$freePeak")
    }
}
