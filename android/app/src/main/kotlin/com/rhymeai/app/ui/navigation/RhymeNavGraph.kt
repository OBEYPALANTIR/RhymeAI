package com.rhymeai.app.ui.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.ui.screens.EditorScreen
import com.rhymeai.app.ui.screens.WelcomeScreen

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
    NavHost(
        navController = navController,
        startDestination = startDestination,
        modifier = modifier,
        enterTransition = { EnterTransition.None },
        exitTransition = { ExitTransition.None },
        popEnterTransition = { EnterTransition.None },
        popExitTransition = { ExitTransition.None }
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
