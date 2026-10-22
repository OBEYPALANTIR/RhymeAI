package com.rhymeai.app.ui.components

import kotlin.math.hypot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class InkBurstMotionTest {
    @Test
    fun `burst tokens follow the spec`() {
        assertEquals(480, InkBurstMotion.DURATION_MILLIS)
        assertEquals(14, InkBurstMotion.DOT_COUNT)
        assertEquals(44f, InkBurstMotion.REACH_DP)
        assertEquals(2.2f, InkBurstMotion.DOT_RADIUS_DP)
        assertEquals(6f, InkBurstMotion.BLOT_RADIUS_DP)
    }

    @Test
    fun `dots sit where the spec formula puts them halfway through`() {
        // Unit offsets before the 44dp reach, from the spec formula; iOS pins the same values.
        val dots = InkBurstMotion.dots(240f)
        val expected = listOf(0.63f to 0.045f, 0.710207f to 0.556107f, 0.469176f to 0.633328f)
        expected.forEachIndexed { i, (x, y) ->
            assertEquals(x, dots[i].x, 1e-4f, "dot $i x")
            assertEquals(y, dots[i].y, 1e-4f, "dot $i y")
        }
    }

    @Test
    fun `fourteen dots and the blot while the burst runs`() {
        val dots = InkBurstMotion.dots(0f)
        assertEquals(15, dots.size)
        assertEquals(InkBurstMotion.BLOT_RADIUS_DP, dots.last().radiusDp)
        assertEquals(1f, dots.last().alpha)
        assertEquals(14, InkBurstMotion.dots(240f).count { it.x != 0f || it.y != 0f })
    }

    @Test
    fun `nothing before the burst or once it has run`() {
        assertTrue(InkBurstMotion.dots(-1f).isEmpty())
        assertTrue(InkBurstMotion.dots(480f).isEmpty())
        assertTrue(InkBurstMotion.dots(10_000f).isEmpty())
    }

    @Test
    fun `dots stay opaque and full size until 70 percent, then fade and shrink`() {
        val early = InkBurstMotion.dots(480f * 0.69f).take(14)
        assertTrue(early.all { it.alpha == 1f && it.radiusDp == InkBurstMotion.DOT_RADIUS_DP })
        val late = InkBurstMotion.dots(480f * 0.9f).take(14)
        assertTrue(late.all { it.alpha < 1f && it.radiusDp < InkBurstMotion.DOT_RADIUS_DP })
        val last = InkBurstMotion.dots(479.9f).take(14)
        assertTrue(last.all { it.radiusDp >= InkBurstMotion.DOT_RADIUS_DP * 0.4f - 1e-4f })
    }

    @Test
    fun `blot collapses as the dots leave`() {
        val blots = (0..470 step 10).mapNotNull { t -> InkBurstMotion.dots(t.toFloat()).getOrNull(14)?.radiusDp }
        assertTrue(blots.zipWithNext().all { (a, b) -> b <= a }, "blots were $blots")
    }

    @Test
    fun `no dot ever passes the reach`() {
        for (t in 0 until 480 step 5) {
            InkBurstMotion.dots(t.toFloat()).forEach { dot ->
                assertTrue(hypot(dot.x, dot.y) <= 1f + 1e-5f, "dot past reach at $t: $dot")
            }
        }
    }
}
