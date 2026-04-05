package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.RhymeContext
import com.rhymeai.app.data.model.RhymeScheme
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.util.SyllableCounter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantPanel(
    viewModel: MainViewModel,
    rhymeContext: RhymeContext,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val textFieldColors = OutlinedTextFieldDefaults.colors(
        unfocusedBorderColor = colorScheme.outlineVariant,
        focusedBorderColor = colorScheme.primary.copy(alpha = 0.5f),
        unfocusedContainerColor = colorScheme.surfaceContainerLow,
        focusedContainerColor = colorScheme.surfaceContainerLow,
        cursorColor = colorScheme.primary,
        unfocusedTextColor = colorScheme.onSurface,
        focusedTextColor = colorScheme.onSurface,
        unfocusedPlaceholderColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
        focusedPlaceholderColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    )

    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
    ) {
        // Context & Theme Section
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { viewModel.isContextExpanded = !viewModel.isContextExpanded },
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(Icons.Default.AutoFixHigh, null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
                    Text("Context & Theme", fontWeight = FontWeight.Medium, fontSize = 16.sp, color = Color.White)
                }
                val arrowRotation by animateFloatAsState(
                    targetValue = if (viewModel.isContextExpanded) 180f else 0f,
                    animationSpec = tween(300),
                    label = "arrow"
                )
                Icon(
                    Icons.Default.ExpandMore,
                    null,
                    tint = Color.White.copy(alpha = 0.4f),
                    modifier = Modifier.graphicsLayer { rotationZ = arrowRotation }
                )
            }

            AnimatedVisibility(
                visible = viewModel.isContextExpanded,
                enter = expandVertically(animationSpec = tween(300)) + fadeIn(animationSpec = tween(300)),
                exit = shrinkVertically(animationSpec = tween(250)) + fadeOut(animationSpec = tween(200))
            ) {
                OutlinedTextField(
                    value = viewModel.theme,
                    onValueChange = { viewModel.onThemeChanged(it) },
                    placeholder = { Text("What is this song about?", fontSize = 13.sp) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 12.dp)
                        .height(100.dp),
                    colors = textFieldColors,
                    shape = RoundedCornerShape(12.dp),
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp)
                )
            }

            if (!viewModel.isContextExpanded && viewModel.theme.isNotEmpty()) {
                Text(
                    viewModel.theme,
                    fontSize = 13.sp,
                    color = Color.White.copy(alpha = 0.5f),
                    maxLines = 1,
                    modifier = Modifier.padding(top = 8.dp)
                )
            }
        }

        // Divider
        Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.1f)))

        // Main controls
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Target Line
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(Icons.Default.Notes, null, tint = Color.White.copy(alpha = 0.7f), modifier = Modifier.size(16.dp))
                        Text("Target Line", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.7f))
                    }
                    if (rhymeContext.targetLine != null) {
                        Box(
                            modifier = Modifier
                                .background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(6.dp))
                                .padding(horizontal = 8.dp, vertical = 4.dp)
                        ) {
                            Text(
                                "${SyllableCounter.countText(rhymeContext.targetLine)} syllables",
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                color = Color.White.copy(alpha = 0.6f)
                            )
                        }
                    }
                }

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White.copy(alpha = 0.05f), RoundedCornerShape(8.dp))
                        .border(1.dp, Color.White.copy(alpha = 0.05f), RoundedCornerShape(8.dp))
                        .padding(16.dp)
                ) {
                    if (rhymeContext.targetLine != null) {
                        Text(
                            "\"${rhymeContext.targetLine}\"",
                            fontFamily = FontFamily.Serif,
                            fontStyle = FontStyle.Italic,
                            color = Color.White.copy(alpha = 0.9f),
                            fontSize = 14.sp
                        )
                    } else {
                        Text(
                            "New rhyme sound (or place cursor on a line)",
                            fontStyle = FontStyle.Italic,
                            color = Color.White.copy(alpha = 0.3f),
                            fontSize = 13.sp
                        )
                    }
                }
            }

            // Rhyme Scheme
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("Rhyme Scheme", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.7f))

                    var expanded by remember { mutableStateOf(false) }
                    ExposedDropdownMenuBox(
                        expanded = expanded,
                        onExpandedChange = { expanded = !expanded }
                    ) {
                        OutlinedTextField(
                            value = viewModel.rhymeScheme.label,
                            onValueChange = {},
                            readOnly = true,
                            modifier = Modifier
                                .menuAnchor(MenuAnchorType.PrimaryNotEditable)
                                .width(130.dp),
                            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp, color = Color.White),
                            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                            colors = textFieldColors,
                            shape = RoundedCornerShape(8.dp),
                            singleLine = true
                        )
                        ExposedDropdownMenu(
                            expanded = expanded,
                            onDismissRequest = { expanded = false },
                            containerColor = Color(0xFF1A1A1A)
                        ) {
                            RhymeScheme.entries.forEach { scheme ->
                                DropdownMenuItem(
                                    text = { Text(scheme.label, color = Color.White, fontSize = 13.sp) },
                                    onClick = {
                                        viewModel.rhymeScheme = scheme
                                        expanded = false
                                    }
                                )
                            }
                        }
                    }
                }

                if (viewModel.rhymeScheme == RhymeScheme.CUSTOM) {
                    OutlinedTextField(
                        value = viewModel.customRhymeScheme,
                        onValueChange = { viewModel.customRhymeScheme = it.uppercase().filter { c -> c.isLetter() } },
                        placeholder = { Text("e.g. AABBCC", fontSize = 13.sp) },
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                        colors = textFieldColors,
                        shape = RoundedCornerShape(8.dp),
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp)
                    )
                }

                // Visual stanza display
                if (viewModel.lyrics.isNotEmpty()) {
                    RhymeSchemeDisplay(
                        rhymeContext = rhymeContext,
                        activeScheme = viewModel.activeRhymeScheme
                    )
                }
            }

            // Rhyme Density
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Rhyme Density", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.7f))
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    RhymeType.entries.forEachIndexed { index, type ->
                        SegmentedButton(
                            selected = viewModel.rhymeType == type,
                            onClick = { viewModel.rhymeType = type },
                            shape = SegmentedButtonDefaults.itemShape(index, RhymeType.entries.size),
                            colors = SegmentedButtonDefaults.colors(
                                activeContainerColor = colorScheme.primary,
                                activeContentColor = Color.White,
                                inactiveContainerColor = Color.Black.copy(alpha = 0.4f),
                                inactiveContentColor = Color.White.copy(alpha = 0.5f),
                                activeBorderColor = colorScheme.primary,
                                inactiveBorderColor = Color.White.copy(alpha = 0.1f)
                            )
                        ) {
                            Text(type.displayName.split(" ")[0], fontSize = 12.sp)
                        }
                    }
                }
            }

            // Toggles
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Highlight Rhymes", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.7f))
                Switch(
                    checked = viewModel.isHighlightEnabled,
                    onCheckedChange = { viewModel.isHighlightEnabled = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color.White,
                        checkedTrackColor = colorScheme.primary,
                        uncheckedThumbColor = Color.White.copy(alpha = 0.7f),
                        uncheckedTrackColor = Color.White.copy(alpha = 0.1f)
                    )
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Color Syllables", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.7f))
                Switch(
                    checked = viewModel.isSyllableColoringEnabled,
                    onCheckedChange = { viewModel.isSyllableColoringEnabled = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color.White,
                        checkedTrackColor = colorScheme.primary,
                        uncheckedThumbColor = Color.White.copy(alpha = 0.7f),
                        uncheckedTrackColor = Color.White.copy(alpha = 0.1f)
                    )
                )
            }

            // Suggest button
            Button(
                onClick = { viewModel.getSuggestions() },
                enabled = viewModel.lyrics.isNotEmpty() && !viewModel.isLoading,
                modifier = Modifier.fillMaxWidth().height(48.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = colorScheme.primary,
                    contentColor = colorScheme.onPrimary,
                    disabledContainerColor = colorScheme.surfaceVariant,
                    disabledContentColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                )
            ) {
                if (viewModel.isLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        color = Color.White,
                        strokeWidth = 2.dp
                    )
                    Text("  Thinking...", fontWeight = FontWeight.Medium)
                } else {
                    Icon(Icons.Default.AutoAwesome, null, modifier = Modifier.size(16.dp))
                    Text("  Suggest Next Line", fontWeight = FontWeight.Medium)
                }
            }

            // Error message
            viewModel.errorMessage?.let {
                Text(it, color = Color.Red.copy(alpha = 0.7f), fontSize = 12.sp)
            }

            // Suggestions
            if (viewModel.suggestions.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Suggestions", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.7f))
                    viewModel.suggestions.forEach { suggestion ->
                        SuggestionCard(
                            suggestion = suggestion,
                            highlightRhyme = viewModel.isHighlightEnabled,
                            onClick = { viewModel.insertSuggestion(suggestion) }
                        )
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            // Footer
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    "Build ${com.rhymeai.app.BuildConfig.VERSION_NAME} (${com.rhymeai.app.BuildConfig.VERSION_CODE})  \u2022  Product of Tyler Manring",
                    fontSize = 11.sp,
                    color = colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                )
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}
