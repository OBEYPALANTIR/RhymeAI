package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class AIServiceFailureTest {

    @Test
    fun cloudStreamSurfacesNoKeyBeforeNetworkWork() = runBlocking {
        val error = assertFailsWith<IllegalStateException> {
            AIService().streamSuggestions(
                provider = AIProvider.GEMINI,
                apiKey = "",
                modelId = AIModel.DEFAULT.id,
                theme = "",
                lyrics = "one line",
                targetRhymeLine = null,
                rhymeType = RhymeType.PERFECT,
                rhymeScheme = "AABB",
                currentLetter = "A",
                currentSection = SongSection.UNKNOWN,
                complexity = RhymeComplexity.MODERATE,
                useWholeSongContext = false
            ).toList()
        }

        assertEquals("No API key set. Go to Settings to add your Gemini API key.", error.message)
    }

    @Test
    fun cloudRewriteAndSynonymsSurfaceNoKeyBeforeNetworkWork() = runBlocking {
        val service = AIService()

        val rewriteError = assertFailsWith<IllegalStateException> {
            service.getRewrite(
                provider = AIProvider.GEMINI,
                apiKey = "",
                modelId = AIModel.DEFAULT.id,
                action = RewriteAction.REPHRASE,
                fullLyrics = "one line",
                selection = "one line",
                currentSection = SongSection.UNKNOWN
            )
        }
        val synonymsError = assertFailsWith<IllegalStateException> {
            service.getSynonyms(
                provider = AIProvider.GEMINI,
                apiKey = "",
                modelId = AIModel.DEFAULT.id,
                word = "line",
                lineContext = "one line"
            )
        }

        assertContains(rewriteError.message.orEmpty(), "No API key set")
        assertContains(synonymsError.message.orEmpty(), "No API key set")
    }

    @Test
    fun localProviderSurfacesNoModelInsteadOfApiKeyError() = runBlocking {
        val service = AIService()

        val streamError = assertFailsWith<IllegalStateException> {
            service.streamSuggestions(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                theme = "",
                lyrics = "one line",
                targetRhymeLine = null,
                rhymeType = RhymeType.PERFECT,
                rhymeScheme = "AABB",
                currentLetter = "A",
                currentSection = SongSection.UNKNOWN,
                complexity = RhymeComplexity.MODERATE,
                useWholeSongContext = false
            ).toList()
        }
        val rewriteError = assertFailsWith<IllegalStateException> {
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.REPHRASE,
                fullLyrics = "one line",
                selection = "one line",
                currentSection = SongSection.UNKNOWN
            )
        }
        val synonymsError = assertFailsWith<IllegalStateException> {
            service.getSynonyms(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                word = "line",
                lineContext = "one line"
            )
        }

        val expected = "No local model loaded. Go to Settings to load a model file."
        assertEquals(expected, streamError.message)
        assertEquals(expected, rewriteError.message)
        assertEquals(expected, synonymsError.message)
    }

    @Test
    fun providerStatusMessagesAreUserFacing() {
        val service = AIService()

        assertEquals(
            "Provider rejected the request — check your API key in Settings.",
            service.userFacingStatusMessageForStatus(401)
        )
        assertEquals(
            "Provider could not find the requested model — pick another in Settings.",
            service.userFacingStatusMessageForStatus(404)
        )
        assertEquals(
            "Provider rate limit reached — wait a moment and retry.",
            service.userFacingStatusMessageForStatus(429)
        )
        assertEquals(
            "Provider service error — try again shortly.",
            service.userFacingStatusMessageForStatus(503)
        )
    }

    @Test
    fun providerNetworkErrorsAreUserFacing() {
        val service = AIService()

        assertEquals(
            "Provider request failed — check your connection and try again.",
            service.userFacingProviderMessageForError(SocketTimeoutException("timeout"))
        )
        assertEquals(
            "Provider request failed — check your connection and try again.",
            service.userFacingProviderMessageForError(UnknownHostException())
        )
        assertEquals(
            "Provider request failed — check your connection and try again.",
            service.userFacingProviderMessageForError(RuntimeException("wrapped", IOException("network down")))
        )
    }

    @Test
    fun blockedProviderResponsesAreUserFacing() {
        val service = AIService()

        assertEquals(
            "Provider blocked the response for safety. Try adjusting the lyric or prompt.",
            service.userFacingProviderMessageForError(RuntimeException("finishReason=SAFETY response blocked"))
        )
    }
}
