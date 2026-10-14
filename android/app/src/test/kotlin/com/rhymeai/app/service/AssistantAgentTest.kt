package com.rhymeai.app.service

import com.rhymeai.app.data.model.AssistantTurn
import com.rhymeai.app.data.model.SongWorkspace
import com.rhymeai.app.util.OpenUILibrary
import com.rhymeai.app.util.OpenUIParser
import com.rhymeai.app.util.OpenUIValue
import com.rhymeai.app.util.toJson
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AssistantAgentTest {

    private val song = OpenUILibrary.AgentSongContext(
        title = "Night Drive",
        theme = "leaving town",
        lyrics = "[Verse]\nWalking down the lonely road",
        wholeSong = true,
        targetLine = "Walking down the lonely road",
        currentLetter = "A",
        rhymeScheme = "AABB",
        sectionName = "Verse",
        rhymeTypeLabel = "Perfect Rhyme",
        complexityLabel = "Moderate",
        complexityHint = "Use a balanced vocabulary."
    )

    @Test
    fun agentPromptUsesChatLibraryShapeActionsAndSongContext() {
        val prompt = OpenUILibrary.generateAgentSystemPrompt(song)
        assertContains(prompt, "root = Card(")
        assertContains(prompt, "FollowUpBlock(")
        assertContains(prompt, "StanzaMap(")
        assertContains(prompt, "## Actions")
        assertContains(prompt, "@ToAssistant(")
        assertContains(prompt, "@ReplaceLine(")
        assertContains(prompt, "Title: Night Drive")
        assertContains(prompt, "Rhyme anchor: \"Walking down the lonely road\"")
        assertFalse(prompt.contains("Query("), "No tools are wired, so Query must not be advertised")
        assertFalse(prompt.contains("ActionChipBar("), "The agent uses FollowUpBlock, not the legacy chip bar")
    }

    @Test
    fun agentPromptMarksExcerptWhenWholeSongIsOff() {
        val prompt = OpenUILibrary.generateAgentSystemPrompt(song.copy(wholeSong = false, lyrics = "Walking down the lonely road"))
        assertContains(prompt, "Lyrics excerpt")
    }

    @Test
    fun parsesAgentReplyWithActionsFormAndFollowUps() {
        val program = """
            root = Card([header, callout, form, actions, follow])
            header = CardHeader("Tighten line 2", "Verse · AABB")
            callout = Callout("warning", "Line 2 runs long", "11 syllables against 8 in line 1.")
            form = Form("details", Buttons([go]), [mood])
            mood = FormControl("Mood", Select("mood", [SelectItem("dark", "Dark"), SelectItem("hopeful", "Hopeful")]))
            go = Button("Continue", @ToAssistant("Here are the details", {line: 2}), "primary")
            actions = Buttons([fix])
            fix = Button("Use shorter line", @ReplaceLine("Walking down the lonely road tonight", "Down the lonely road"), "secondary")
            follow = FollowUpBlock([f1, f2])
            f1 = FollowUpItem("Make it darker")
            f2 = FollowUpItem("Check the chorus")
        """.trimIndent()

        val result = OpenUIParser.parse(program, rootComponentName = "Card", forceComplete = true)
        assertNotNull(result.root)
        assertTrue(result.meta.errors.isEmpty(), "Unexpected errors: ${result.meta.errors}")
        assertTrue(result.meta.unresolved.isEmpty(), "Unresolved: ${result.meta.unresolved}")

        val children = result.root!!.childrenProp("children")
        assertEquals(listOf("CardHeader", "Callout", "Form", "Buttons", "FollowUpBlock"), children.map { it.typeName })

        val goButton = children[2].props["buttons"].let { (it as OpenUIValue.Element).node }.childrenProp("children").single()
        val action = (goButton.props["action"] as OpenUIValue.Element).node
        assertEquals("@ToAssistant", action.typeName)
        assertEquals("Here are the details", action.stringProp("message"))

        val replace = (children[3].childrenProp("children").single().props["action"] as OpenUIValue.Element).node
        assertEquals("@ReplaceLine", replace.typeName)
        assertEquals("Down the lonely road", replace.stringProp("replacement"))

        assertEquals(listOf("Make it darker", "Check the chorus"), children[4].childrenProp("items").map { it.stringProp("text") })
    }

    @Test
    fun toJsonEscapesStringsAndNestsObjects() {
        val value = OpenUIValue.Obj(
            linkedMapOf(
                "line" to OpenUIValue.Num(2.0),
                "text" to OpenUIValue.Str("say \"hi\"\nnow"),
                "tags" to OpenUIValue.Arr(listOf(OpenUIValue.BoolVal(true), OpenUIValue.NullVal))
            )
        )
        assertEquals("""{"line":2,"text":"say \"hi\"\nnow","tags":[true,null]}""", value.toJson())
    }

    @Test
    fun normalizeChatTurnsStartsWithUserAndMergesSameRoleTurns() {
        val service = AIService()
        val normalized = service.normalizeChatTurns(
            listOf(
                AIService.ChatTurn("assistant", "orphan reply"),
                AIService.ChatTurn("user", "first"),
                AIService.ChatTurn("user", "retry after error"),
                AIService.ChatTurn("assistant", "root = Card([])"),
                AIService.ChatTurn("user", "  ")
            )
        )
        assertEquals(listOf("user", "assistant"), normalized.map { it.role })
        assertEquals("first\n\nretry after error", normalized[0].content)
    }

    @Test
    fun geminiChatBodyUsesSystemInstructionAndModelRole() {
        val body = AIService().buildGeminiChatRequestBody(
            "SYSTEM",
            listOf(AIService.ChatTurn("user", "hi"), AIService.ChatTurn("assistant", "root = Card([])"))
        )
        val system = body["systemInstruction"]!!.jsonObject["parts"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content
        assertEquals("SYSTEM", system)
        val roles = body["contents"]!!.jsonArray.map { it.jsonObject["role"]!!.jsonPrimitive.content }
        assertEquals(listOf("user", "model"), roles)
    }

    @Test
    fun openAIChatBodyPutsSystemFirstAndOmitsTemperature() {
        val body = AIService().buildOpenAIChatTurnsRequestBody("gpt-4.1", "SYSTEM", listOf(AIService.ChatTurn("user", "hi")))
        val messages = body["messages"]!!.jsonArray
        assertEquals("system", messages[0].jsonObject["role"]!!.jsonPrimitive.content)
        assertEquals("user", messages[1].jsonObject["role"]!!.jsonPrimitive.content)
        assertNull(body["temperature"])
        assertEquals("true", body["stream"]!!.jsonPrimitive.content)
    }

    @Test
    fun claudeChatBodyUsesTopLevelSystemAndLargerBudget() {
        val body = AIService().buildClaudeChatTurnsRequestBody("claude-sonnet-4-20250514", "SYSTEM", listOf(AIService.ChatTurn("user", "hi")))
        assertEquals("SYSTEM", body["system"]!!.jsonPrimitive.content)
        assertEquals("4096", body["max_tokens"]!!.jsonPrimitive.content)
        assertEquals(1, body["messages"]!!.jsonArray.size)
    }

    @Test
    fun songWorkspaceKeepsOnlyTheMostRecentAssistantTurns() {
        var workspace = SongWorkspace()
        repeat(SongWorkspace.MAX_ASSISTANT_TURNS + 5) { i ->
            workspace = workspace.appendAssistantTurn(AssistantTurn(role = AssistantTurn.USER, text = "m$i", createdAt = i.toLong()))
        }
        assertEquals(SongWorkspace.MAX_ASSISTANT_TURNS, workspace.assistantTurns.size)
        assertEquals("m5", workspace.assistantTurns.first().text)
    }
}
