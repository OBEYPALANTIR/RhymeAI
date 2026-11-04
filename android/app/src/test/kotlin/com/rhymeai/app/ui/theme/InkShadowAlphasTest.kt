package com.rhymeai.app.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Test

class InkShadowAlphasTest {
    @Test
    fun `spot and ambient are compensated by their own platform multipliers`() {
        // 12% visible: spot 0.12 / 0.19; ambient caps at full colour (0.039 is its ceiling).
        val (spot, ambient) = inkShadowAlphas(0.12f)
        assertEquals(0.12f / 0.19f, spot, 1e-4f)
        assertEquals(1f, ambient, 0f)

        val (faintSpot, faintAmbient) = inkShadowAlphas(0.02f)
        assertEquals(0.02f / 0.19f, faintSpot, 1e-4f)
        assertEquals(0.02f / 0.039f, faintAmbient, 1e-4f)
    }
}
