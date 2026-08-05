package com.rhymeai.app

import android.app.Activity
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.platform.LocalDensity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.lifecycleScope
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

@OptIn(ExperimentalComposeUiApi::class)
class MainActivity : ComponentActivity() {
    private val mainViewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen().setKeepOnScreenCondition { !mainViewModel.appearanceLoaded }
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
            val viewModel = mainViewModel
            RhymeAITheme(
                appearance = viewModel.appAppearance,
                analysisPresentation = viewModel.analysisPresentation
            ) {
                val darkSystemBars = viewModel.appAppearance.isDark
                DisposableEffect(window, darkSystemBars) {
                    WindowInsetsControllerCompat(window, window.decorView).apply {
                        isAppearanceLightStatusBars = !darkSystemBars
                        isAppearanceLightNavigationBars = !darkSystemBars
                    }
                    onDispose {}
                }
                val density = LocalDensity.current
                val lifecycleOwner = LocalLifecycleOwner.current

                DisposableEffect(lifecycleOwner, viewModel) {
                    val observer = LifecycleEventObserver { _, event ->
                        if (event == Lifecycle.Event.ON_STOP) {
                            viewModel.triggerBackgroundDriveSync()
                        }
                    }
                    lifecycleOwner.lifecycle.addObserver(observer)
                    onDispose {
                        lifecycleOwner.lifecycle.removeObserver(observer)
                    }
                }

                // Drive authorization consent screen. After the user approves,
                // retry the same action that requested consent (sync or restore).
                val driveAuthLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.StartIntentSenderForResult()
                ) { result ->
                    if (result.resultCode == Activity.RESULT_OK) {
                        viewModel.retryAfterDriveAuthorization()
                    } else {
                        viewModel.syncPendingIntent = null
                    }
                }

                androidx.compose.runtime.LaunchedEffect(viewModel.syncPendingIntent) {
                    val intent = viewModel.syncPendingIntent ?: return@LaunchedEffect
                    driveAuthLauncher.launch(
                        IntentSenderRequest.Builder(intent.intentSender).build()
                    )
                }
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
                    val navController = rememberNavController()

                    // Determine start destination
                    val startDest = if (viewModel.showStartMenu) Routes.WELCOME else Routes.EDITOR
                    val navModifier =
                        if (
                            viewModel.showProjectsDialog ||
                            viewModel.showTemplatesDialog ||
                            viewModel.showSettingsDialog
                        ) {
                            Modifier.clearAndSetSemantics {}
                        } else {
                            Modifier
                        }

                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .semantics {
                                testTagsAsResourceId = BuildConfig.BENCHMARK
                            }
                    ) {
                    RhymeNavGraph(
                        navController = navController,
                        viewModel = viewModel,
                        startDestination = startDest,
                        modifier = navModifier
                    )

                    // Handle dialog navigation to the editor without rebuilding it unnecessarily.
                    if (viewModel.showProjectsDialog) {
                        ProjectsDrawer(
                            projects = viewModel.projects,
                            trashedProjects = viewModel.trashedProjects,
                            currentProjectId = viewModel.currentProjectId,
                            onLoadProject = { project ->
                                viewModel.loadProject(project)
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
                                }
                            },
                            onNewProject = {
                                viewModel.newProject()
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
                                }
                            },
                            onDeleteProject = { viewModel.moveProjectToTrash(it) },
                            onRestoreProject = { viewModel.restoreTrashedProject(it) },
                            onPermanentlyDeleteProject = { viewModel.permanentlyDeleteTrashedProject(it) },
                            onPurgeExpiredTrash = { viewModel.purgeExpiredTrashedProjects() },
                            onImportProject = { project ->
                                viewModel.importProject(project)
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
                                }
                            },
                            onDismiss = { viewModel.showProjectsDialog = false },
                            service = viewModel.voiceMemoService
                        )
                    }

                    if (viewModel.showTemplatesDialog) {
                        TemplatesDialog(
                            onSelectTemplate = { name, theme, lyrics ->
                                viewModel.applyTemplate(name, theme, lyrics)
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
                                }
                            },
                            onDismiss = { viewModel.showTemplatesDialog = false }
                        )
                    }

                    if (viewModel.showSettingsDialog) {
                        SettingsDialog(
                            currentAppearance = viewModel.appAppearance,
                            onAppearanceChange = viewModel::setAppAppearance,
                            currentAnalysisPresentation = viewModel.analysisPresentation,
                            onAnalysisPresentationChange = viewModel::setAnalysisPresentation,
                            apiKeyPresence = viewModel.apiKeyPresence,
                            currentProvider = viewModel.selectedProvider,
                            currentModel = viewModel.selectedModel,
                            localModelLoading = viewModel.localModelLoading,
                            localModelLoaded = viewModel.localModelLoaded,
                            localModelPath = viewModel.localModelPath,
                            localModelError = viewModel.localModelError,
                            savedLocalModels = viewModel.savedLocalModels,
                            selectedLocalModelId = viewModel.selectedLocalModelId,
                            onSaveApiKey = { provider, key -> viewModel.saveApiKey(provider, key) },
                            onSaveProvider = { viewModel.saveProvider(it) },
                            onSaveModel = { viewModel.saveModel(it) },
                            onRegisterLocalModel = { path, name ->
                                viewModel.registerAndSelectLocalModel(path, name, isCustom = true)
                            },
                            onSelectSavedLocalModel = viewModel::selectSavedLocalModel,
                            onUnloadLocalModel = { viewModel.unloadLocalModel() },
                            gemmaDownloadingModel = viewModel.gemmaDownloadingModel,
                            gemmaDownloadProgress = viewModel.gemmaDownloadProgress,
                            gemmaDownloadVerifying = viewModel.gemmaDownloadVerifying,
                            gemmaDownloadError = viewModel.gemmaDownloadError,
                            gemmaLastDownloadAttempt = viewModel.gemmaLastDownloadAttempt,
                            gemmaDownloadRevision = viewModel.gemmaDownloadRevision,
                            onStartGemmaDownload = { viewModel.startGemmaDownload(it) },
                            onUseDownloadedGemma = { viewModel.useDownloadedGemma(it) },
                            syncPassphraseStored = viewModel.syncPassphraseStored,
                            syncInProgress = viewModel.syncInProgress,
                            syncLastResult = viewModel.syncLastResult,
                            syncProgressLabel = viewModel.syncProgressLabel,
                            onSaveSyncPassphrase = { viewModel.saveSyncPassphrase(it) },
                            onSyncNow = { viewModel.triggerSync() },
                            onRestoreNow = { viewModel.triggerRestore() },
                            // Editor toggles — each change is persisted via viewModel.persistEditorToggles().
                            useWholeSongContext = viewModel.useWholeSongContext,
                            onWholeSongContextChange = { viewModel.useWholeSongContext = it; viewModel.persistEditorToggles() },
                            isStressPreviewEnabled = viewModel.isStressPreviewEnabled,
                            onStressPreviewChange = { viewModel.isStressPreviewEnabled = it; viewModel.persistEditorToggles() },
                            isHighlightEnabled = viewModel.isHighlightEnabled,
                            onHighlightChange = { viewModel.isHighlightEnabled = it; viewModel.persistEditorToggles() },
                            isSyllableColoringEnabled = viewModel.isSyllableColoringEnabled,
                            onSyllableColoringChange = { viewModel.isSyllableColoringEnabled = it; viewModel.persistEditorToggles() },
                            isRhymeHighlightEnabled = viewModel.isRhymeHighlightEnabled,
                            onRhymeHighlightChange = { viewModel.isRhymeHighlightEnabled = it; viewModel.persistEditorToggles() },
                            isBeatGridEnabled = viewModel.isBeatGridEnabled,
                            onBeatGridChange = { viewModel.isBeatGridEnabled = it; viewModel.persistEditorToggles() },
                            onDismiss = { viewModel.showSettingsDialog = false }
                        )
                    }
                    }
                }
            }
        }
    }
}
