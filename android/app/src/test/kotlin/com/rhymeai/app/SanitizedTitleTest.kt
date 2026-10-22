package com.rhymeai.app

import kotlin.test.Test
import kotlin.test.assertEquals

class SanitizedTitleTest {
    @Test
    fun enterNewlineIsRemoved() {
        assertEquals("Borrowed Train", sanitizedTitle("Borrowed Train\n"))
    }

    @Test
    fun windowsLineBreakIsRemoved() {
        assertEquals("Borrowed Train", sanitizedTitle("Borrowed\r\n Train\r\n"))
    }

    @Test
    fun innerAndEdgeSpacesAreKept() {
        assertEquals(" Borrowed  Train ", sanitizedTitle(" Borrowed  Train "))
    }
}
