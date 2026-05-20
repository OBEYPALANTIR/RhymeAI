package com.rhymeai.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.rememberNavController
import com.rhymeai.app.ui.components.ProjectsDrawer
import com.rhymeai.app.ui.components.SettingsDialog
import com.rhymeai.app.ui.components.TemplatesDialog
import com.rhymeai.app.ui.navigation.RhymeNavGraph
import com.rhymeai.app.ui.navigation.Routes
import com.rhymeai.app.ui.theme.RhymeAITheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            RhymeAITheme {
                val viewModel: MainViewModel = viewModel()
                val navController = rememberNavController()

                // Determine start destination
                val startDest = if (viewModel.showStartMenu) Routes.WELCOME else Routes.EDITOR

                RhymeNavGraph(
                    navController = navController,
                    viewModel = viewModel,
                    startDestination = startDest
                )

                // Handle dialog navigation from welcome screen
                if (viewModel.showProjectsDialog) {
                    ProjectsDrawer(
                        projects = viewModel.projects,
                        currentProjectId = viewModel.currentProjectId,
                        onLoadProject = { project ->
                            viewModel.loadProject(project)
                            navController.navigate(Routes.EDITOR) {
                                popUpTo(0) { inclusive = true }
                            }
                        },
                        onNewProject = {
                            viewModel.newProject()
                            navController.navigate(Routes.EDITOR) {
                                popUpTo(0) { inclusive = true }
                            }
                        },
                        onDeleteProject = { viewModel.deleteProject(it) },
                        onImportProject = { project ->
                            viewModel.importProject(project)
                            navController.navigate(Routes.EDITOR) {
                                popUpTo(0) { inclusive = true }
                            }
                        },
                        onDismiss = { viewModel.showProjectsDialog = false }
                    )
                }

                if (viewModel.showTemplatesDialog) {
                    TemplatesDialog(
                        onSelectTemplate = { name, theme, lyrics ->
                            viewModel.applyTemplate(name, theme, lyrics)
                            navController.navigate(Routes.EDITOR) {
                                popUpTo(0) { inclusive = true }
                            }
                        },
                        onDismiss = { viewModel.showTemplatesDialog = false }
                    )
                }

                if (viewModel.showSettingsDialog) {
                    SettingsDialog(
                        apiKeys = viewModel.apiKeys,
                        currentProvider = viewModel.selectedProvider,
                        currentModel = viewModel.selectedModel,
                        localModelLoading = viewModel.localModelLoading,
                        localModelLoaded = viewModel.localModelLoaded,
                        localModelPath = viewModel.localModelPath,
                        localModelError = viewModel.localModelError,
                        onSaveApiKey = { provider, key -> viewModel.saveApiKey(provider, key) },
                        onSaveProvider = { viewModel.saveProvider(it) },
                        onSaveModel = { viewModel.saveModel(it) },
                        onLoadLocalModel = { viewModel.loadLocalModel(it) },
                        onUnloadLocalModel = { viewModel.unloadLocalModel() },
                        onDismiss = { viewModel.showSettingsDialog = false }
                    )
                }
            }
        }
    }
}
