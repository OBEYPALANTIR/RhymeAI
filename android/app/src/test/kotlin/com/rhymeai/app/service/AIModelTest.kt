package com.rhymeai.app.service

import kotlin.test.Test
import kotlin.test.assertEquals

class AIModelTest {

    @Test
    fun geminiModelPickerStartsWithCurrentGeminiModels() {
        val modelIds = AIModel.modelsForProvider(AIProvider.GEMINI).map { it.id }

        assertEquals(
            listOf(
                "gemini-3.8-flash",
                "gemini-4-argon",
                "gemini-3.7-flash",
                "gemini-3.6-flash",
                "gemini-3.5-flash",
                "gemini-3.5-flash-lite",
                "gemini-3.1-pro-preview",
                "gemini-3-flash-preview",
                "gemini-3.1-flash-lite-preview",
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite"
            ),
            modelIds
        )
    }

    @Test
    fun openAIModelPickerStartsWithCurrentGPTModels() {
        val modelIds = AIModel.modelsForProvider(AIProvider.OPENAI).map { it.id }

        assertEquals(
            listOf(
                "gpt-6-astra",
                "gpt-6.1-sol",
                "gpt-6-sol",
                "gpt-6-luna",
                "gpt-6-instant",
                "gpt-5.5",
                "gpt-5.5-pro",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.4-nano",
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "gpt-4o",
                "gpt-4o-mini"
            ),
            modelIds
        )
    }

    @Test
    fun claudeModelPickerUsesCurrentClaudeModels() {
        val modelIds = AIModel.modelsForProvider(AIProvider.CLAUDE).map { it.id }

        assertEquals(
            listOf(
                "claude-fable-5-1",
                "claude-fable-5",
                "claude-opus-5-5",
                "claude-sonnet-5-5",
                "claude-haiku-5-5",
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-opus-4-20250514",
                "claude-sonnet-4-20250514",
                "claude-haiku-4-5-20251001"
            ),
            modelIds
        )
    }

    @Test
    fun localModelPickerUsesOnDeviceModelOnly() {
        val models = AIModel.modelsForProvider(AIProvider.LOCAL)

        assertEquals(listOf(AIModel.LOCAL_MODEL), models)
        assertEquals("local-model", models.single().id)
        assertEquals("On-Device Model", models.single().displayName)
    }

    @Test
    fun fromIdRestoresNewProviderModels() {
        assertEquals(AIModel.GEMINI_38_FLASH, AIModel.fromId("gemini-3.8-flash"))
        assertEquals(AIModel.GEMINI_4_ARGON, AIModel.fromId("gemini-4-argon"))
        assertEquals(AIModel.GPT_6_ASTRA, AIModel.fromId("gpt-6-astra"))
        assertEquals(AIModel.GPT_55, AIModel.fromId("gpt-5.5"))
        assertEquals(AIModel.GPT_54_MINI, AIModel.fromId("gpt-5.4-mini"))
        assertEquals(AIModel.CLAUDE_FABLE_51, AIModel.fromId("claude-fable-5-1"))
        assertEquals(AIModel.CLAUDE_OPUS_47, AIModel.fromId("claude-opus-4-7"))
        assertEquals(AIModel.CLAUDE_SONNET_46, AIModel.fromId("claude-sonnet-4-6"))
    }
}

