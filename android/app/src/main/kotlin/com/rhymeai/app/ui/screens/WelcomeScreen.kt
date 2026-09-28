package com.rhymeai.app.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.rhymeai.app.R
import com.rhymeai.app.ui.components.bottomSafeActionPadding
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.appWritingSurface

@Composable
fun WelcomeScreen(
    onNewSong: () -> Unit,
    onLoadSong: () -> Unit,
    onTemplates: () -> Unit,
    recentSongTitle: String? = null,
    onContinue: () -> Unit = {}
) {
    val colorScheme = MaterialTheme.colorScheme

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .appWritingSurface()
            .statusBarsPadding()
            .bottomSafeActionPadding(extra = DesignTokens.Spacing.xl)
    ) {
        val isCompact = maxHeight < 600.dp
        val iconSize = if (isCompact) 56.dp else 80.dp
        val verticalSpacing = if (isCompact) DesignTokens.Spacing.lg else DesignTokens.Spacing.xxl

        Column(
            modifier = Modifier
                .fillMaxSize()
                .wrapContentWidth(Alignment.CenterHorizontally)
                .widthIn(max = DesignTokens.Drawer.expandedWidth)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DesignTokens.Spacing.xl, vertical = verticalSpacing),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            // App icon
            Surface(
                modifier = Modifier
                    .size(iconSize),
                shape = RoundedCornerShape(iconSize * 0.22f),
                color = colorScheme.primaryContainer,
                tonalElevation = 4.dp,
                shadowElevation = 6.dp,
                border = BorderStroke(1.dp, colorScheme.primary.copy(alpha = 0.24f))
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(iconSize * 0.14f),
                    contentAlignment = Alignment.Center
                ) {
                    Image(
                        painter = painterResource(R.mipmap.ic_launcher_foreground),
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                        colorFilter = ColorFilter.tint(colorScheme.onPrimaryContainer)
                    )
                }
            }

            Spacer(Modifier.height(verticalSpacing))

            // Title
            Text(
                text = "Writers Block",
                style = MaterialTheme.typography.headlineMedium,
                color = colorScheme.primary,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(DesignTokens.Spacing.md))

            Text(
                "A space for your next song.",
                color = colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = DesignTokens.Spacing.sm)
            )

            Spacer(Modifier.height(verticalSpacing))

            // Cards
            Column(
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
                modifier = Modifier.fillMaxWidth()
            ) {
                if (recentSongTitle != null) {
                    WelcomeCard(Icons.Default.FolderOpen, "Continue $recentSongTitle", "Return to your writing", onContinue)
                }
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

    OutlinedCard(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth(),
        shape = RoundedCornerShape(DesignTokens.Radius.xxl),
        colors = CardDefaults.outlinedCardColors(
            containerColor = colorScheme.surfaceContainerLow,
            contentColor = colorScheme.onSurface
        ),
        border = BorderStroke(1.dp, colorScheme.outlineVariant)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.lg, vertical = DesignTokens.Spacing.lg),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = colorScheme.primary,
                modifier = Modifier.size(28.dp)
            )
            Spacer(Modifier.width(DesignTokens.Spacing.lg))
            Column(
                modifier = Modifier
                    .weight(1f)
                    .testTag("welcomeCardText"),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                Text(
                    title,
                    fontWeight = FontWeight.Medium,
                    style = MaterialTheme.typography.titleMedium,
                    color = colorScheme.onSurface
                )
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
