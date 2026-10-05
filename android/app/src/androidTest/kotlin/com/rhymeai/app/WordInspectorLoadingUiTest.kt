package com.rhymeai.app

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import com.rhymeai.app.ui.components.WordInspectorSheet
import com.rhymeai.app.ui.theme.RhymeAITheme
import com.rhymeai.app.util.RhymeMatches
import com.rhymeai.app.util.WordProsody
import org.junit.Rule
import org.junit.Test

/** The first rhyme lookup of a session takes seconds; the sheet must not call that "no rhymes". */
class WordInspectorLoadingUiTest {
    @get:Rule val compose = createComposeRule()

    private val prosody = mutableStateOf<WordProsody?>(null)
    private val matches = mutableStateOf<RhymeMatches?>(null)

    @Test fun pendingLookupShowsLoadingInsteadOfEmptyRhymes() {
        compose.setContent {
            RhymeAITheme {
                WordInspectorSheet(
                    word = "harbor",
                    prosody = prosody.value,
                    matches = matches.value,
                    synonyms = emptyList(),
                    synonymsLoading = false,
                    synonymsError = null,
                    onReplace = {},
                    onRetrySynonyms = {},
                    onDismiss = {}
                )
            }
        }

        compose.onNodeWithTag("wordInspectorRhymesLoading").assertIsDisplayed()
        compose.onNodeWithText("Finding rhymes…").assertIsDisplayed()
        compose.onNodeWithText("No perfect rhymes in dictionary.").assertDoesNotExist()
        compose.onNodeWithText("No near rhymes found.").assertDoesNotExist()

        compose.runOnIdle {
            prosody.value = WordProsody("harbor", "harbor", 2, listOf(1, 0), "ˈhɑrbɚ", isFallback = false)
        }
        compose.onNodeWithText("/ˈhɑrbɚ/").assertIsDisplayed()
        compose.onNodeWithText("2 syllables").assertIsDisplayed()
        compose.onNodeWithTag("wordInspectorRhymesLoading").assertIsDisplayed()

        compose.runOnIdle {
            matches.value = RhymeMatches(perfect = listOf("arbor", "barber"), near = emptyList(), multi = emptyList())
        }
        compose.onNodeWithTag("wordInspectorRhymesLoading").assertDoesNotExist()
        compose.onNodeWithText("arbor").assertIsDisplayed()
        compose.onNodeWithText("No near rhymes found.").assertIsDisplayed()
    }
}
