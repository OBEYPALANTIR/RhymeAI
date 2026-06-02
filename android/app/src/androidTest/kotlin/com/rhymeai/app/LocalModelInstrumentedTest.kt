package com.rhymeai.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.service.LocalModelService
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LocalModelInstrumentedTest {
    @Test
    fun localGgufModelLoadsAndGeneratesText() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val modelPath = InstrumentationRegistry.getArguments().getString("localModelPath").orEmpty()
        assumeTrue(
            "Set instrumentation argument localModelPath to run the live GGUF smoke test.",
            modelPath.isNotBlank()
        )

        val modelFile = File(modelPath)
        assertTrue("Model file does not exist at $modelPath", modelFile.exists())
        assertTrue("Model file is not readable at $modelPath", modelFile.canRead())

        val service = LocalModelService()
        service.initialize(instrumentation.targetContext)

        try {
            service.loadModel(modelPath)
            val response = service.generateResponse(
                "Write one short, original songwriting line. Return only the line."
            )

            assertTrue("Local model returned blank output", response.isNotBlank())
        } finally {
            service.unload()
        }
    }
}
