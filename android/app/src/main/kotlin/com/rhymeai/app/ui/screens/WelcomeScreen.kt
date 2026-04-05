package com.rhymeai.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.MusicNote
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

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colorScheme.background)
            .statusBarsPadding(),
        contentAlignment = Alignment.Center
    ) {
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
                .fillMaxWidth()
                .padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Icon
            Box(
                modifier = Modifier
                    .size(80.dp)
                    .background(colorScheme.primary.copy(alpha = 0.2f), CircleShape)
                    .border(1.dp, colorScheme.primary.copy(alpha = 0.3f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.MusicNote,
                    contentDescription = null,
                    tint = colorScheme.primary,
                    modifier = Modifier.size(40.dp)
                )
            }

            Spacer(Modifier.height(32.dp))

            // Title
            Text(
                text = buildAnnotatedString {
                    withStyle(SpanStyle(color = colorScheme.onBackground)) {
                        append("Welcome to ")
                    }
                    withStyle(SpanStyle(
                        brush = Brush.horizontalGradient(listOf(colorScheme.primary, colorScheme.secondary))
                    )) {
                        append("WritersBLOK")
                    }
                },
                fontFamily = FontFamily.Serif,
                fontWeight = FontWeight.Bold,
                fontSize = 32.sp,
                textAlign = TextAlign.Center,
                lineHeight = 40.sp
            )

            Spacer(Modifier.height(12.dp))

            Text(
                "Your intelligent songwriting companion. Start from scratch, load an existing project, or kickstart your creativity with a template.",
                color = colorScheme.onSurfaceVariant,
                fontSize = 15.sp,
                textAlign = TextAlign.Center,
                lineHeight = 22.sp,
                modifier = Modifier.padding(horizontal = 8.dp)
            )

            Spacer(Modifier.height(48.dp))

            // Cards
            Column(
                verticalArrangement = Arrangement.spacedBy(16.dp),
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

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colorScheme.surfaceVariant.copy(alpha = 0.5f), RoundedCornerShape(16.dp))
            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = colorScheme.onSurfaceVariant,
            modifier = Modifier.size(32.dp)
        )
        Spacer(Modifier.height(12.dp))
        Text(
            title,
            fontWeight = FontWeight.Medium,
            fontSize = 18.sp,
            color = colorScheme.onSurface
        )
        Spacer(Modifier.height(4.dp))
        Text(
            subtitle,
            fontSize = 13.sp,
            color = colorScheme.onSurfaceVariant
        )
    }
}
