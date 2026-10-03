package com.rhymeai.app.ui.motion

import com.rhymeai.app.BuildConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class RewriteMotionStyleTest {
    @Test
    fun canonicalBuildUsesRippleMotion() {
        if (!BuildConfig.REWRITE_MOTION_STYLE_IS_OVERRIDE) {
            assertEquals("ripple", BuildConfig.REWRITE_MOTION_STYLE)
        }
    }

    @Test
    fun buildValuesParseToDistinctMotionStyles() {
        assertEquals(RewriteMotionStyle.PENCIL, RewriteMotionStyle.fromBuildValue("pencil"))
        assertEquals(RewriteMotionStyle.RIPPLE, RewriteMotionStyle.fromBuildValue("ripple"))
        assertEquals(RewriteMotionStyle.PAPER, RewriteMotionStyle.fromBuildValue("paper"))
    }

    @Test
    fun unknownBuildValueIsRejected() {
        assertFailsWith<IllegalArgumentException> {
            RewriteMotionStyle.fromBuildValue("shimmer")
        }
    }

    @Test
    fun motionStylesExposeStableBuildValues() {
        assertEquals(
            setOf("pencil", "ripple", "paper"),
            RewriteMotionStyle.entries.mapTo(mutableSetOf()) { it.buildValue }
        )
    }
}
