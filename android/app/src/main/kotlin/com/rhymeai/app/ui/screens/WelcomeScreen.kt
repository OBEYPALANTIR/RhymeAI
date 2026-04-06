package com.rhymeai.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.ui.theme.Purple400

@Composable
fun WelcomeScreen(
    onNewSong: () -> Unit,
    onLoadSong: () -> Unit,
    onTemplates: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(colorScheme.background)
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        val isCompact = maxHeight < 600.dp
        val iconSize = if (isCompact) 56.dp else 80.dp
        val titleSize = if (isCompact) 24.sp else 32.sp
        val verticalSpacing = if (isCompact) 16.dp else 32.dp

        // Gradient overlay
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colors = listOf(
                            colorScheme.primary.copy(alpha = 0.1f),
                            Color.Transparent
                        )
                    )
                )
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = verticalSpacing),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            // Icon
            Box(
                modifier = Modifier
                    .size(iconSize)
                    .background(colorScheme.primary.copy(alpha = 0.2f), CircleShape)
                    .border(1.dp, colorScheme.primary.copy(alpha = 0.3f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.Keyboard,
                    contentDescription = null,
                    tint = colorScheme.primary,
                    modifier = Modifier.size(iconSize / 2)
                )
            }

            Spacer(Modifier.height(verticalSpacing))

            // Title
            Text(
                text = buildAnnotatedString {
                    withStyle(SpanStyle(
                        brush = Brush.horizontalGradient(listOf(colorScheme.primary, colorScheme.secondary))
                    )) {
                        append("Writers Block")
                    }
                },
                fontFamily = FontFamily.Serif,
                fontWeight = FontWeight.Bold,
                fontSize = titleSize,
                textAlign = TextAlign.Center,
                lineHeight = titleSize * 1.25
            )

            Spacer(Modifier.height(12.dp))

            Text(
                "Your intelligent songwriting companion. Start from scratch, load an existing project, or kickstart your creativity with a template.",
                color = colorScheme.onSurfaceVariant,
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
                lineHeight = 20.sp,
                modifier = Modifier.padding(horizontal = 8.dp)
            )

            Spacer(Modifier.height(verticalSpacing))

            // Cards
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                WelcomeCard(
                    icon = Icons.Default.Add,
                    title = "New Song",
                    subtitle = "Start with a blank canvas",
                    onClick = onNewSong
                )
                WelcomeCard(
                    icon = Icons.Default.FolderOpen,
                    title = "Load Song",
                    subtitle = "Continue where you left off",
                    onClick = onLoadSong
                )
                WelcomeCard(
                    icon = Icons.Default.GridView,
                    title = "Song Templates",
                    subtitle = "Start with a structured layout",
                    onClick = onTemplates
                )
            }
        }
    }
}

@Composable
private fun WelcomeCard(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colorScheme.surfaceVariant.copy(alpha = 0.5f), RoundedCornerShape(16.dp))
            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = colorScheme.onSurfaceVariant,
            modifier = Modifier.size(28.dp)
        )
        Spacer(Modifier.width(16.dp))
        Column {
            Text(
                title,
                fontWeight = FontWeight.Medium,
                fontSize = 16.sp,
                color = colorScheme.onSurface
            )
            Text(
                subtitle,
                fontSize = 13.sp,
                color = colorScheme.onSurfaceVariant
            )
        }
    }
}
