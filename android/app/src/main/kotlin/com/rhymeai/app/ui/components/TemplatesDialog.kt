package com.rhymeai.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.data.model.SONG_TEMPLATES

@Composable
fun TemplatesDialog(
    onSelectTemplate: (name: String, theme: String, lyrics: String) -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            contentAlignment = Alignment.Center
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                color = colorScheme.surfaceContainerLow,
                contentColor = colorScheme.onSurface,
                tonalElevation = 6.dp,
                border = BorderStroke(1.dp, colorScheme.outlineVariant)
            ) {
                Column(modifier = Modifier.fillMaxWidth()) {
                // Header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(20.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(Icons.Default.GridView, null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
                        Text("Choose a Template", fontWeight = FontWeight.Medium, fontSize = 18.sp, color = colorScheme.onSurface)
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                    }
                }

                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp)
                        .padding(bottom = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    SONG_TEMPLATES.forEach { template ->
                        OutlinedCard(
                            onClick = { onSelectTemplate(template.name, template.theme, template.lyrics) },
                            modifier = Modifier
                                .fillMaxWidth(),
                            shape = RoundedCornerShape(12.dp),
                            colors = CardDefaults.outlinedCardColors(
                                containerColor = colorScheme.surfaceContainer,
                                contentColor = colorScheme.onSurface
                            ),
                            border = BorderStroke(1.dp, colorScheme.outlineVariant)
                        ) {
                            Column(modifier = Modifier.padding(20.dp)) {
                                Text(
                                    template.name,
                                    fontWeight = FontWeight.Medium,
                                    fontSize = 16.sp,
                                    color = colorScheme.onSurface
                                )
                                Text(
                                    template.theme,
                                    fontSize = 13.sp,
                                    color = colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(top = 4.dp)
                                )
                            }
                        }
                    }
                }
                }
            }
        }
    }
}
