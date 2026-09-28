package com.rhymeai.app.data.model

import kotlin.test.Test
import kotlin.test.assertEquals

class AppAppearanceTest {
    @Test
    fun defaultsToInkForMissingOrUnknownValues() {
        assertEquals(AppAppearance.INK, AppAppearance.fromStorage(null))
        assertEquals(AppAppearance.INK, AppAppearance.fromStorage("neon"))
    }

    @Test
    fun roundTripsEveryStableStorageValue() {
        AppAppearance.entries.forEach { appearance ->
            assertEquals(appearance, AppAppearance.fromStorage(appearance.storageValue))
        }
    }
}
