package com.rhymeai.app.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.ui.theme.DesignTokens

@Composable
internal fun AppearanceSelector(
    currentAppearance: AppAppearance,
    onAppearanceChange: (AppAppearance) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier) {
        Text(
            text = "Appearance",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(DesignTokens.Spacing.sm))
        SlidingSegmentedControl(
            labels = AppAppearance.entries.map(AppAppearance::displayName),
            selectedIndex = AppAppearance.entries.indexOf(currentAppearance),
            onSelect = { onAppearanceChange(AppAppearance.entries[it]) },
            modifier = Modifier
                .fillMaxWidth()
                .testTag("appearanceSelector")
                .semantics { stateDescription = currentAppearance.displayName }
        )
    }
}
