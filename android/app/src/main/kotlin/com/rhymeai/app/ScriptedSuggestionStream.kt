package com.rhymeai.app

import android.content.Intent
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * A deterministic stand-in for the suggestion stream, for UI tests and
 * emulator QA. It holds a request in its loading state for [holdMillis], then
 * emits [count] lines [intervalMillis] apart, with no provider key, network
 * request or model. It is armed only in debug builds, through
 * [MainViewModel.enableScriptedSuggestionsForTesting], and the view model
 * consumes it exactly as it consumes a real stream, so what gets exercised is
 * the Assistant's production loading, arrival and cancellation UI.
 *
 * Launch the isolated QA debug build with it armed (`-S` stops a running copy
 * first, so the extras reach a fresh activity):
 * ```
 * ./gradlew :app:installDebug -PisolatedMotionQaApp=true
 * adb shell am start -S -n com.rhymeai.app.motionqa/com.rhymeai.app.MainActivity \
 *   --ez com.rhymeai.app.SCRIPTED_SUGGESTIONS true \
 *   --el com.rhymeai.app.SCRIPTED_SUGGESTIONS_HOLD_MS 3000 \
 *   --el com.rhymeai.app.SCRIPTED_SUGGESTIONS_INTERVAL_MS 1000 \
 *   --ei com.rhymeai.app.SCRIPTED_SUGGESTIONS_COUNT 5
 * ```
 * The three timing extras are optional and default to the values shown; a
 * count of 0 exercises the empty-answer path. The stream changes no provider,
 * key or setting; it only answers Suggest Next Line for that process.
 */
class ScriptedSuggestionStream(
    val holdMillis: Long = DEFAULT_HOLD_MILLIS,
    val intervalMillis: Long = DEFAULT_INTERVAL_MILLIS,
    val count: Int = DEFAULT_COUNT
) {
    /** The scripted lines this stream delivers, in order. */
    val scriptedLines: List<String> get() = LINES.take(count.coerceIn(0, LINES.size))

    fun lines(): Flow<SuggestedLine> = flow {
        delay(holdMillis.coerceAtLeast(0))
        scriptedLines.forEachIndexed { index, text ->
            if (index > 0) delay(intervalMillis.coerceAtLeast(0))
            emit(SuggestedLine(text = text, rhymeTier = 0))
        }
    }

    companion object {
        const val EXTRA = "com.rhymeai.app.SCRIPTED_SUGGESTIONS"
        const val EXTRA_HOLD_MS = "com.rhymeai.app.SCRIPTED_SUGGESTIONS_HOLD_MS"
        const val EXTRA_INTERVAL_MS = "com.rhymeai.app.SCRIPTED_SUGGESTIONS_INTERVAL_MS"
        const val EXTRA_COUNT = "com.rhymeai.app.SCRIPTED_SUGGESTIONS_COUNT"
        const val DEFAULT_HOLD_MILLIS = 3000L
        const val DEFAULT_INTERVAL_MILLIS = 1000L
        const val DEFAULT_COUNT = 5

        /**
         * Lines of mixed length, the same as iOS `UITestFlags.scriptedSuggestionLines`;
         * the fourth runs long enough to wrap, so a card landing on two lines is covered.
         */
        val LINES = listOf(
            "A quiet light carries me home",
            "The porch still hums the songs we used to know",
            "I count the streetlights back to you",
            "Every window on this road has learned the shape of your name and keeps it lit past midnight",
            "So the quiet doesn't feel the same",
            "And the radio plays on"
        )

        fun fromIntent(intent: Intent): ScriptedSuggestionStream = ScriptedSuggestionStream(
            holdMillis = intent.getLongExtra(EXTRA_HOLD_MS, DEFAULT_HOLD_MILLIS),
            intervalMillis = intent.getLongExtra(EXTRA_INTERVAL_MS, DEFAULT_INTERVAL_MILLIS),
            count = intent.getIntExtra(EXTRA_COUNT, DEFAULT_COUNT)
        )
    }
}
