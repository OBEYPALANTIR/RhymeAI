package com.rhymeai.app.ui.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.ui.screens.EditorScreen
import com.rhymeai.app.ui.screens.WelcomeScreen
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled

object Routes {
    const val WELCOME = "welcome"
    const val EDITOR = "editor"
}

@Composable
fun RhymeNavGraph(
    navController: NavHostController,
    viewModel: MainViewModel,
    startDestination: String = Routes.WELCOME,
    modifier: Modifier = Modifier
) {
    // Welcome and editor cross-fade in place on the page tier; nothing travels.
    val pageFade = tween<Float>(
        if (LocalAnimationsEnabled.current) DesignTokens.Motion.pageFadeMillis else 0,
        easing = DesignTokens.Motion.standardEasing
    )
    NavHost(
        navController = navController,
        startDestination = startDestination,
        modifier = modifier,
        enterTransition = { fadeIn(pageFade) },
        exitTransition = { fadeOut(pageFade) },
        popEnterTransition = { fadeIn(pageFade) },
        popExitTransition = { fadeOut(pageFade) }
    ) {
        composable(Routes.WELCOME) {
            WelcomeScreen(
                recentSongTitle = viewModel.recentProject?.title?.ifBlank { "Untitled Song" },
                onContinue = {
                    viewModel.recentProject?.let { project ->
                        viewModel.loadProject(project) {
                            navController.navigate(Routes.EDITOR) { popUpTo(Routes.WELCOME) { inclusive = true } }
                        }
                    }
                },
                onNewSong = {
                    viewModel.newProject {
                        navController.navigate(Routes.EDITOR) { popUpTo(Routes.WELCOME) { inclusive = true } }
                    }
                },
                onLoadSong = {
                    viewModel.showProjectsDialog = true
                },
                onTemplates = {
                    viewModel.showTemplatesDialog = true
                }
            )
        }
        composable(Routes.EDITOR) {
            val navigateToWelcome = {
                viewModel.goToStartMenu {
                    navController.navigate(Routes.WELCOME) { popUpTo(0) { inclusive = true } }
                }
            }

            BackHandler(onBack = navigateToWelcome)
            EditorScreen(
                viewModel = viewModel,
                onNavigateToStart = navigateToWelcome
            )
        }
    }
}
