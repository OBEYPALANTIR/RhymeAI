package com.rhymeai.app.ui.components

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class InkBurstMotionTest {
    @Test
    fun `the burst starts as a blot where the spinner was`() {
        val dots = InkBurstMotion.particles(0f)
        assertEquals(InkBurstMotion.PARTICLE_COUNT, dots.size)
        assertTrue(dots.all { hypot(it.x, it.y) < 0.001f && it.alpha == 1f })
        assertEquals(InkBurstMotion.BLOT_RADIUS_DP, InkBurstMotion.blot(0f).radiusDp)
        assertEquals(1f, InkBurstMotion.blot(0f).alpha)
    }

    @Test
    fun `dots leave fast, coast, and never pass the reach`() {
        val early = InkBurstMotion.particles(0.25f).map { hypot(it.x, it.y) }
        val late = InkBurstMotion.particles(0.75f).map { hypot(it.x, it.y) }
        val end = InkBurstMotion.particles(1f).map { hypot(it.x, it.y) }
        assertTrue(early.zip(late).all { (a, b) -> b > a }, "dots keep moving outward")
        assertTrue(early.average() > 0.3f, "a quarter in, the dots are already well on their way")
        assertTrue(end.all { it <= 1.0001f }, "no dot flies past the reach, drop included")
        assertTrue(InkBurstMotion.particles(0.9f).all { hypot(it.x, it.y) <= 1.0001f })
    }

    @Test
    fun `dots hold their ink then fade out by the end`() {
        assertEquals(1f, InkBurstMotion.alpha(0.5f))
        assertTrue(InkBurstMotion.alpha(0.85f) in 0.4f..0.6f)
        assertEquals(0f, InkBurstMotion.alpha(1f))
        assertTrue(InkBurstMotion.particles(1f).all { it.alpha == 0f })
    }

    @Test
    fun `dots keep their size in flight, then shrink to 40 percent as they fade`() {
        val full = InkBurstMotion.DOT_RADIUS_DP
        assertTrue(InkBurstMotion.particles(0.5f).all { abs(it.radiusDp - full) < 0.0001f }, "no shrinking before the fade")
        assertTrue(InkBurstMotion.particles(0.69f).all { abs(it.radiusDp - full) < 0.0001f })
        assertTrue(InkBurstMotion.particles(0.85f).all { it.radiusDp < full && it.radiusDp > full * 0.4f }, "shrinking with the fade")
        assertTrue(InkBurstMotion.particles(1f).all { abs(it.radiusDp - full * 0.4f) < 0.0001f }, "40 percent by the end")
    }

    @Test
    fun `the blot collapses as the dots leave`() {
        assertTrue(InkBurstMotion.blot(0.5f).radiusDp < InkBurstMotion.blot(0.1f).radiusDp)
        assertEquals(0f, InkBurstMotion.blot(1f).radiusDp)
        assertEquals(0f, InkBurstMotion.blot(1f).alpha)
    }

    @Test
    fun `wet ink drops a little on its way out`() {
        val dots = InkBurstMotion.particles(1f)
        val meanY = dots.map { it.y }.average()
        assertTrue(meanY > 0.1, "the ring's centre of mass sits below the origin, was $meanY")
    }

    @Test
    fun `the ring is not a gear`() {
        val angles = InkBurstMotion.particles(0.5f).map { Math.atan2(it.y.toDouble(), it.x.toDouble()) }.sorted()
        val gaps = angles.zipWithNext { a, b -> b - a }
        assertTrue(gaps.max() - gaps.min() > 0.05, "jitter varies the spacing between dots")
    }
}
