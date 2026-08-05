package com.rhymeai.benchmark

import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RhymeAIMacrobenchmark {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    @Test
    fun coldStartup() = benchmarkRule.measureRepeated(
        packageName = PACKAGE_NAME,
        metrics = listOf(StartupTimingMetric()),
        compilationMode = CompilationMode.None(),
        startupMode = StartupMode.COLD,
        iterations = 10
    ) {
        pressHome()
        startActivityAndWait()
    }

    @Test
    fun editorTypingScrollAndAssistant() = benchmarkRule.measureRepeated(
        packageName = PACKAGE_NAME,
        metrics = listOf(FrameTimingMetric()),
        compilationMode = CompilationMode.Partial(),
        iterations = 5,
        setupBlock = {
            pressHome()
            startPerformanceEditor()
        }
    ) {
        val editor = device.findObject(By.res("lyricsEditor"))
        checkNotNull(editor) { "Lyrics editor was not exposed to UI Automator" }
        editor.click()
        editor.text = editor.text + "\nA measured line keeps time inside the light"
        device.swipe(
            device.displayWidth / 2,
            device.displayHeight * 3 / 4,
            device.displayWidth / 2,
            device.displayHeight / 4,
            24
        )
        device.swipe(
            device.displayWidth / 2,
            device.displayHeight / 4,
            device.displayWidth / 2,
            device.displayHeight * 3 / 4,
            24
        )

        check(device.wait(Until.hasObject(By.res("unBlockAction")), UI_TIMEOUT_MILLIS)) {
            "UnBlock action was not available after editing"
        }
        val unblock = device.findObject(By.res("unBlockAction"))
        checkNotNull(unblock) { "UnBlock action was not exposed to UI Automator" }
        unblock.click()
        device.wait(Until.hasObject(By.text("Assistant")), UI_TIMEOUT_MILLIS)
        device.pressBack()
        device.wait(Until.hasObject(By.res("unBlockAction")), UI_TIMEOUT_MILLIS)
    }

    @Test
    fun appearanceSwitching() = benchmarkRule.measureRepeated(
        packageName = PACKAGE_NAME,
        metrics = listOf(FrameTimingMetric()),
        compilationMode = CompilationMode.Partial(),
        iterations = 5,
        setupBlock = {
            pressHome()
            startPerformanceEditor()
            val settings = device.findObject(By.desc("Settings"))
            checkNotNull(settings) { "Settings action was not exposed to UI Automator" }
            settings.click()
            check(device.wait(Until.hasObject(By.text("Appearance")), UI_TIMEOUT_MILLIS)) {
                "Appearance settings were not visible"
            }
        }
    ) {
        listOf("Paper", "Graphite", "Ink").forEach { appearance ->
            val option = device.findObject(By.text(appearance))
            checkNotNull(option) { "$appearance appearance option was not visible" }
            option.click()
            device.waitForIdle()
        }
    }

    @Test
    fun recordingAnimation() = benchmarkRule.measureRepeated(
        packageName = PACKAGE_NAME,
        metrics = listOf(FrameTimingMetric()),
        compilationMode = CompilationMode.Partial(),
        iterations = 5,
        setupBlock = {
            pressHome()
            startPerformanceEditor(fakeRecording = true)
        }
    ) {
        device.waitForIdle()
        Thread.sleep(1_500)
    }

    private fun MacrobenchmarkScope.startPerformanceEditor(fakeRecording: Boolean = false) {
        val fakeRecordingArgument = if (fakeRecording) {
            " --ez $FAKE_RECORDING_EXTRA true"
        } else {
            ""
        }
        device.executeShellCommand(
            "am start -W -S -n $PACKAGE_NAME/.MainActivity" + fakeRecordingArgument
        )
        check(device.wait(Until.hasObject(By.text("New Song")), UI_TIMEOUT_MILLIS)) {
            "New Song action was not exposed to UI Automator"
        }
        val newSongText = device.findObject(By.text("New Song"))
        checkNotNull(newSongText?.parent?.parent) { "New Song card was not clickable" }.click()
        check(device.wait(Until.hasObject(By.res("lyricsEditor")), UI_TIMEOUT_MILLIS)) {
            "lyricsEditor was not exposed to UI Automator"
        }
        if (!fakeRecording) {
            device.findObject(By.res("lyricsEditor")).text = BASELINE_LYRICS
        }
        check(!fakeRecording || device.wait(Until.hasObject(By.res("micButton")), UI_TIMEOUT_MILLIS)) {
            "micButton was not exposed to UI Automator"
        }
    }

    private companion object {
        const val PACKAGE_NAME = "com.rhymeai.app"
        const val FAKE_RECORDING_EXTRA = "com.rhymeai.app.FAKE_RECORDING"
        const val UI_TIMEOUT_MILLIS = 5_000L
        val BASELINE_LYRICS = List(12) {
            """
            [Verse]
            Midnight writes a signal through the rain
            Paper holds the echo of the train
            Every quiet measure finds a name
            Every final cadence lights the flame
            """.trimIndent()
        }.joinToString("\n\n")
    }
}
