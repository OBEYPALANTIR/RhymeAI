package com.rhymeai.app.ui.navigation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class OneLinerActionTest {
    @Test
    fun parsesEachRouteAndRoundTripsItsLink() {
        assertEquals(OneLinerAction.RECORD, OneLinerAction.parse("writersblock://one-liners/record"))
        assertEquals(OneLinerAction.TYPE, OneLinerAction.parse("writersblock://one-liners/type"))
        assertEquals(OneLinerAction.OPEN, OneLinerAction.parse("writersblock://one-liners/open"))
        OneLinerAction.entries.forEach { assertEquals(it, OneLinerAction.parse(it.link)) }
    }

    @Test
    fun bareHostOpensTheScreenAndCaseDoesNotMatter() {
        assertEquals(OneLinerAction.OPEN, OneLinerAction.parse("writersblock://one-liners"))
        assertEquals(OneLinerAction.OPEN, OneLinerAction.parse("writersblock://one-liners/"))
        assertEquals(OneLinerAction.RECORD, OneLinerAction.parse("WritersBlock://One-Liners/Record"))
        assertEquals(OneLinerAction.TYPE, OneLinerAction.parse("writersblock://one-liners/type?from=widget"))
    }

    @Test
    fun rejectsOtherLinks() {
        assertNull(OneLinerAction.parse(null))
        assertNull(OneLinerAction.parse(""))
        assertNull(OneLinerAction.parse("writersblock://songs/record"))
        assertNull(OneLinerAction.parse("https://one-liners/record"))
        assertNull(OneLinerAction.parse("writersblock://one-liners/stop"))
        assertNull(OneLinerAction.parse("not a link at all"))
    }
}
