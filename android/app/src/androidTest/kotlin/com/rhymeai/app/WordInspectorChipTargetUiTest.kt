package com.rhymeai.app

import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.components.WordInspectorSheet
import com.rhymeai.app.ui.theme.RhymeAITheme
import com.rhymeai.app.util.RhymeMatches
import com.rhymeai.app.util.WordProsody
import org.junit.Rule
import org.junit.Test

/** Material 3 asks for 48 x 48 dp touch targets; the inspector's suggestion chips must meet it for tap and long-press. */
class WordInspectorChipTargetUiTest {
    @get:Rule val compose = createComposeRule()

    // The sheet is a Dialog with its own window density, so font scale is checked on a device, not here.
    @Test fun chipsHave48dpTouchTarget() {
        compose.setContent {
            RhymeAITheme {
                WordInspectorSheet(
                    word = "harbor",
                    prosody = WordProsody("harbor", "harbor", 2, listOf(1, 0), "ˈhɑrbɚ", isFallback = false),
                    // "ar" is short enough to test width as well as height.
                    matches = RhymeMatches(perfect = listOf("arbor", "ar"), near = listOf("garden"), multi = emptyList()),
                    synonyms = listOf("port"),
                    synonymsLoading = false,
                    synonymsError = null,
                    onReplace = {},
                    onRetrySynonyms = {},
                    onDismiss = {}
                )
            }
        }

        listOf("arbor", "ar", "garden", "port").forEach { label ->
            compose.onNode(hasText(label) and hasClickAction(), useUnmergedTree = false)
                .assertHeightIsAtLeast(48.dp)
                .assertWidthIsAtLeast(48.dp)
        }
    }
}
