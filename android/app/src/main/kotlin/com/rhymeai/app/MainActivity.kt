package com.rhymeai.app

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.rememberNavController
import com.rhymeai.app.ui.components.LocalImeBottom
import com.rhymeai.app.ui.components.LocalNavBottom
import com.rhymeai.app.ui.components.LocalStatusBarTop
import com.rhymeai.app.ui.components.ProjectsDrawer
import com.rhymeai.app.ui.components.SettingsDialog
import com.rhymeai.app.ui.components.TemplatesDialog
import com.rhymeai.app.ui.navigation.RhymeNavGraph
import com.rhymeai.app.ui.navigation.Routes
import com.rhymeai.app.ui.theme.RhymeAITheme
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.WordFrequency
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        lifecycleScope.launch(Dispatchers.IO) {
            runCatching {
                if (PronunciationDictionary.shared.wordCount == 0) {
                    assets.open("cmudict-rhymeai.tsv").use(PronunciationDictionary::initialize)
                }
            }.onFailure { error ->
                Log.w("RhymeAI", "Falling back to heuristic syllable counts; CMU dictionary failed to load.", error)
            }
            runCatching {
                if (!WordFrequency.shared.isLoaded) {
                    assets.open("word-frequency.txt").use(WordFrequency.shared::initialize)
                }
            }.onFailure { error ->
                Log.w("RhymeAI", "Word frequency list failed to load; rhyme candidates will use dictionary order.", error)
            }
        }
        enableEdgeToEdge()
        setContent {
            RhymeAITheme {
                val density = LocalDensity.current
                val navigationBars = WindowInsets.navigationBars
                val imeInsets = WindowInsets.ime
                val statusBars = WindowInsets.statusBars
                val navBottom by remember(density, navigationBars) {
                    derivedStateOf {
                        with(density) { navigationBars.getBottom(density).toDp() }
                    }
                }
                val imeBottom by remember(density, imeInsets) {
                    derivedStateOf {
                        with(density) { imeInsets.getBottom(density).toDp() }
                    }
                }
                val topInset by remember(density, statusBars) {
                    derivedStateOf {
                        with(density) { statusBars.getTop(density).toDp() }
                    }
                }

                CompositionLocalProvider(
                    LocalNavBottom provides navBottom,
                    LocalImeBottom provides imeBottom,
                    LocalStatusBarTop provides topInset
                ) {
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
                            trashedProjects = viewModel.trashedProjects,
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
                            onDeleteProject = { viewModel.moveProjectToTrash(it) },
                            onRestoreProject = { viewModel.restoreTrashedProject(it) },
                            onPermanentlyDeleteProject = { viewModel.permanentlyDeleteTrashedProject(it) },
                            onPurgeExpiredTrash = { viewModel.purgeExpiredTrashedProjects() },
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
                            apiKeyPresence = viewModel.apiKeyPresence,
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
}
