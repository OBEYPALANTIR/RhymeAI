package com.rhymeai.app.service

import kotlin.test.Test
import kotlin.test.assertEquals

class AIModelTest {

    @Test
    fun openAIModelPickerStartsWithCurrentGPTModels() {
        val modelIds = AIModel.modelsForProvider(AIProvider.OPENAI).map { it.id }

        assertEquals(
            listOf(
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
        assertEquals(AIModel.GPT_55, AIModel.fromId("gpt-5.5"))
        assertEquals(AIModel.GPT_54_MINI, AIModel.fromId("gpt-5.4-mini"))
        assertEquals(AIModel.CLAUDE_OPUS_47, AIModel.fromId("claude-opus-4-7"))
        assertEquals(AIModel.CLAUDE_SONNET_46, AIModel.fromId("claude-sonnet-4-6"))
    }
}
