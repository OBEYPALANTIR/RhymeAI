package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.service.AIService
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class OpenUILangTest {

    @Test
    fun autoCloseClosesUnclosedQuotesAndBracketsMidStream() {
        val raw = "root = Stack([meter, g1\ns1 = SuggestionLine(\"The static on the pavement glowed"
        val closed = OpenUIParser.autoClose(raw)
        assertTrue(closed.wasIncomplete)
        assertTrue(closed.text.endsWith("\")]" + ")"))
        assertTrue(closed.text.contains("s1 = SuggestionLine(\"The static on the pavement glowed\""))
    }

    @Test
    fun streamingParserResolvesForwardReferencesProgressively() {
        val parser = OpenUIStreamingParser()
        val buffer = StringBuilder()

        // Chunk 1: root declared first referencing meter, g1, actions before they exist
        buffer.append("root = Stack([meter, g1, actions])\n")
        val step1 = parser.set(buffer.toString(), isComplete = false)
        val root1 = step1.root
        assertNotNull(root1)
        assertEquals("Stack", root1.typeName)
        assertTrue(step1.meta.unresolved.containsAll(listOf("meter", "g1", "actions")))

        // Chunk 2: meter arrives
        buffer.append("meter = ProsodyMeter(\"Walking down the lonely road\", \"da-DUM da-DUM\", \"/oʊd/\")\n")
        val step2 = parser.set(buffer.toString(), isComplete = false)
        val rootChildrenAfter2 = step2.root?.childrenProp("children").orEmpty()
        assertEquals(1, rootChildrenAfter2.size)
        val meterNode = rootChildrenAfter2[0]
        assertEquals("ProsodyMeter", meterNode.typeName)
        assertEquals("Walking down the lonely road", meterNode.stringProp("line"))
        assertEquals("/oʊd/", meterNode.stringProp("cadenceNote"))

        // Chunk 3: g1 arrives referencing s1 and s2, then s1 arrives mid-string
        buffer.append("g1 = RhymeGroup(\"Perfect Rhymes\", [s1, s2], \"/oʊd/\", \"Direct imagery\")\n")
        buffer.append("s1 = SuggestionLine(\"The static on the pavement glowed\", \"Sensory detail\", \"glowed\"")
        val step3 = parser.set(buffer.toString(), isComplete = false)
        val rootChildrenAfter3 = step3.root?.childrenProp("children").orEmpty()
        assertEquals(2, rootChildrenAfter3.size)
        val groupNode = rootChildrenAfter3[1]
        assertEquals("RhymeGroup", groupNode.typeName)
        val groupSuggestions = groupNode.childrenProp("suggestions")
        assertEquals(1, groupSuggestions.size)
        val s1Node = groupSuggestions[0]
        assertEquals("The static on the pavement glowed", s1Node.stringProp("text"))
        assertTrue(step3.meta.incomplete)

        // Chunk 4: finish s1, add s2 and actions
        buffer.append(
            ")\ns2 = SuggestionLine(\"A heavy promise that we owed\", \"Stakes\", \"owed\")\n" +
                "actions = ActionChipBar(\"Steer direction\", [\"More imagery\", \"Tighter meter\"])\n"
        )
        val step4 = parser.set(buffer.toString(), isComplete = true)
        assertEquals(2, step4.extractedSuggestions.size)
        assertEquals("The static on the pavement glowed", step4.extractedSuggestions[0])
        assertEquals("A heavy promise that we owed", step4.extractedSuggestions[1])
        assertTrue(step4.meta.unresolved.isEmpty())
        assertFalse(step4.meta.incomplete)
    }

    @Test
    fun synthesizeTreeBuildsOpenUITreeFromVerifiedLines() {
        val tree = OpenUILibrary.synthesizeTree(
            suggestions = listOf(
                com.rhymeai.app.SuggestedLine("The static on the pavement glowed", rhymeTier = 2),
                com.rhymeai.app.SuggestedLine("A heavy promise that we owed", rhymeTier = 2)
            ),
            targetLine = "Walking down the lonely road",
            rhymeTypeLabel = "Perfect Rhyme",
            schemeLabel = "AABB (A)",
            sectionLabel = "Verse"
        )
        assertEquals("Stack", tree.typeName)
        val children = tree.childrenProp("children")
        assertTrue(children.any { it.typeName == "ProsodyMeter" })
        assertTrue(children.any { it.typeName == "RhymeGroup" })
        assertTrue(children.any { it.typeName == "ActionChipBar" })
    }

    @Test
    fun buildOpenUIPromptIncludesOpenUILangGrammarAndRefinementDirective() {
        val service = AIService()
        val prompt = service.buildOpenUIPrompt(
            theme = "late night drive",
            lyrics = "[Verse]\nWalking down the lonely road",
            targetRhymeLine = "Walking down the lonely road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.VERSE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true,
            refinementDirective = "More imagery"
        )
        assertContains(prompt, "openui-lang")
        assertContains(prompt, "root = Stack(")
        assertContains(prompt, "SuggestionLine(")
        assertContains(prompt, "Refinement focus requested by writer: \"More imagery\"")
    }

    @Test
    fun emitOpenUIFromTokensStreamsProgressiveAstAndFinalFilteredSuggestions() = runBlocking {
        val service = AIService()
        val updates = mutableListOf<AIService.OpenUIStreamUpdate>()
        val tokenStream = flow {
            emit("root = Stack([g1])\n")
            emit("g1 = RhymeGroup(\"Perfect\", [s1, s2])\n")
            emit("s1 = SuggestionLine(\"The static on the pavement glowed\", \"Sensory\", \"glowed\")\n")
            emit("s2 = SuggestionLine(\"A heavy promise that we owed\", \"Stakes\", \"owed\")\n")
        }

        flow {
            with(service) {
                emitOpenUIFromTokens(
                    tokens = tokenStream,
                    constraint = null,
                    targetRhymeLine = "Walking down the lonely road",
                    rhymeType = RhymeType.PERFECT,
                    rhymeScheme = "AABB",
                    currentSection = SongSection.VERSE
                )
            }
        }.collect { updates.add(it) }

        assertTrue(updates.size >= 2)
        val finalUpdate = updates.last()
        assertFalse(finalUpdate.parseResult.meta.incomplete)
        assertEquals(2, finalUpdate.suggestions.size)
        assertEquals("The static on the pavement glowed", finalUpdate.suggestions[0].text)
    }

    @Test
    fun parsesTicketTrackerQueryMutationAndReactiveBindingsWithoutErrors() {
        val code = """
            root = Stack([CardHeader("Ticket Tracker"), form, tbl])
            ${'$'}title = ""
            ${'$'}priority = "medium"
            createResult = Mutation("create_ticket", {title: ${'$'}title, priority: ${'$'}priority})
            tickets = Query("list_tickets", {}, {rows: []})
            submitBtn = Button("Create", Action([@Run(createResult), @Run(tickets), @Reset(${'$'}title, ${'$'}priority)]), "primary")
            form = Form("create", Buttons([submitBtn]), [
              FormControl("Title", Input("title", "Ticket title", "text", {required: true}, ${'$'}title)),
              FormControl("Priority", Select("priority", [
                SelectItem("low", "Low"), SelectItem("medium", "Medium"), SelectItem("high", "High")
              ], null, null, ${'$'}priority))
            ])
            tbl = Table([Col("Title", tickets.rows.title), Col("Priority", tickets.rows.priority)])
        """.trimIndent()

        val result = OpenUIParser.parse(code, forceComplete = true)
        assertNotNull(result.root)
        assertTrue(result.meta.errors.isEmpty(), "Expected no parse errors, got: ${result.meta.errors}")
        assertTrue(result.meta.unresolved.isEmpty(), "Expected no unresolved refs, got: ${result.meta.unresolved}")
        assertEquals("", result.stateDeclarations["title"]?.asString())
        assertEquals("medium", result.stateDeclarations["priority"]?.asString())
        assertEquals("list_tickets", result.queries["tickets"]?.stringProp("toolName"))
        assertEquals("create_ticket", result.mutations["createResult"]?.stringProp("toolName"))

        val rootChildren = result.root?.childrenProp("children").orEmpty()
        assertEquals(3, rootChildren.size)
        assertEquals("CardHeader", rootChildren[0].typeName)
        assertEquals("Form", rootChildren[1].typeName)
        assertEquals("Table", rootChildren[2].typeName)

        val cols = rootChildren[2].childrenProp("columns")
        assertEquals(2, cols.size)
        val firstColData = cols[0].props["data"] as? OpenUIValue.PropPath
        assertNotNull(firstColData)
        assertEquals("tickets", firstColData.rootName)
        assertEquals(listOf("rows", "title"), firstColData.path)
    }

    @Test
    fun mergeStatementsAppliesIncrementalPatchPreservingQueriesAndState() {
        val turn1 = """
            root = Stack([header, tbl])
            header = CardHeader("Tickets")
            tickets = Query("list_tickets", {}, {rows: []})
            tbl = Table([Col("Title", tickets.rows.title)])
        """.trimIndent()

        val turn2Patch = """
            root = Stack([header, chart, tbl])
            chart = CardHeader("Ticket Volume")
        """.trimIndent()

        val merged = OpenUIParser.mergeStatements(turn1, turn2Patch)
        val parsed = OpenUIParser.parse(merged, forceComplete = true)
        assertTrue(parsed.meta.unresolved.isEmpty())
        assertEquals("list_tickets", parsed.queries["tickets"]?.stringProp("toolName"))
        val children = parsed.root?.childrenProp("children").orEmpty()
        assertEquals(listOf("CardHeader", "CardHeader", "Table"), children.map { it.typeName })
    }

    @Test
    fun generateSystemPromptIncludesAvailableToolsAndQueryDefaults() {
        val tools = listOf(
            OpenUIToolSpec(
                name = "list_drafts",
                description = "List saved lyric drafts",
                outputSignature = "{rows?: {title?: string}[]}",
                defaultJson = "{\"rows\":[]}"
            )
        )
        val prompt = OpenUILibrary.generateSystemPrompt(tools = tools, toolCalls = true, bindings = true)
        assertContains(prompt, "## Available Tools")
        assertContains(prompt, "list_drafts()")
        assertContains(prompt, "{\"rows\":[]}")
        assertContains(prompt, "Query(toolName")
    }

    @Test
    fun generateSystemPromptWithoutToolsHidesDataAndFormComponents() {
        val prompt = OpenUILibrary.generateSystemPrompt()
        assertFalse(prompt.contains("Query("), "Query must not be advertised without tools")
        assertFalse(prompt.contains("Mutation("), "Mutation must not be advertised without tools")
        assertFalse(prompt.contains("Form("), "Form must not be advertised without tools")
        assertFalse(prompt.contains("## Available Tools"))
        assertContains(prompt, "RhymeGroup(")
    }

    @Test
    fun buildOpenUIPromptLetsModelChooseLayout() {
        val prompt = AIService().buildOpenUIPrompt(
            theme = "",
            lyrics = "Walking down the lonely road",
            targetRhymeLine = "Walking down the lonely road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = false
        )
        assertFalse(prompt.contains("2 `RhymeGroup` components"), "Prompt must not hard-code the layout")
        assertContains(prompt, "Choose the layout that best fits")
    }

    @Test
    fun emitOpenUIFromTokensKeepsMoreThanSixLinesSoGroupsAreNotPruned() = runBlocking {
        val service = AIService()
        val lines = (1..8).joinToString("\n") { i -> "s$i = SuggestionLine(\"Distinct candidate line number $i here\", \"Angle\", \"here\")" }
        val program = "root = Stack([g1, g2])\n" +
            "g1 = RhymeGroup(\"First\", [s1, s2, s3, s4])\n" +
            "g2 = RhymeGroup(\"Second\", [s5, s6, s7, s8])\n" + lines
        val updates = mutableListOf<AIService.OpenUIStreamUpdate>()
        flow {
            with(service) { emitOpenUIFromTokens(tokens = flow { emit(program) }) }
        }.collect { updates.add(it) }

        val final = updates.last()
        assertEquals(8, final.suggestions.size)
        val groups = final.parseResult.root?.childrenProp("children").orEmpty()
        assertEquals(2, groups.size)
        assertEquals(4, groups[1].childrenProp("suggestions").size)
    }
}
