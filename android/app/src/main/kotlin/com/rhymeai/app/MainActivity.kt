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
import com.rhymeai.app.ui.components.BackupSectionActions
import com.rhymeai.app.ui.components.BackupSectionState
import com.rhymeai.app.ui.components.RestoreOfferSheet
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
            RhymeAITheme(appearance = viewModel.appAppearance) {
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
                            viewModel.onBackground()
                            viewModel.flushCurrentDraft()
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

                    viewModel.cloudAISharingRequest?.let { request ->
                        androidx.compose.material3.AlertDialog(
                            onDismissRequest = viewModel::cancelCloudAISharing,
                            title = { androidx.compose.material3.Text("Share ${request.scope.label.lowercase()} with ${request.provider.displayName}?") },
                            text = {
                                androidx.compose.material3.Text(
                                    "For ${request.purpose}, suggestions share the target line, theme and rhyme settings; rewrites share the selected passage; synonyms share the selected word and current line. " +
                                    (if (request.scope == CloudAISharingScope.WHOLE_SONG) "This request also shares your full lyric. " else "") +
                                    "Your API key is sent directly to ${request.provider.displayName} for authentication. Permission applies to this provider and scope. You can revoke it in Settings."
                                )
                            },
                            confirmButton = { androidx.compose.material3.TextButton(onClick = { viewModel.approveCloudAISharing(request) }, enabled = !viewModel.cloudAIConsentSaving) { androidx.compose.material3.Text("Allow sharing") } },
                            dismissButton = { androidx.compose.material3.TextButton(onClick = viewModel::cancelCloudAISharing) { androidx.compose.material3.Text("Cancel") } }
                        )
                    }

                    viewModel.restoreOffer?.let { offer ->
                        RestoreOfferSheet(
                            offer = offer,
                            onRestore = viewModel::acceptRestoreOffer,
                            onNotNow = viewModel::declineRestoreOffer
                        )
                    }

                    viewModel.persistenceError?.let { message ->
                        androidx.compose.material3.AlertDialog(
                            onDismissRequest = { viewModel.persistenceError = null },
                            title = { androidx.compose.material3.Text("Could not complete action") },
                            text = { androidx.compose.material3.Text(message) },
                            confirmButton = { androidx.compose.material3.TextButton(onClick = { viewModel.persistenceError = null }) { androidx.compose.material3.Text("OK") } }
                        )
                    }

                    // Handle dialog navigation to the editor without rebuilding it unnecessarily.
                    if (viewModel.showProjectsDialog) {
                        ProjectsDrawer(
                            projects = viewModel.projects,
                            trashedProjects = viewModel.trashedProjects,
                            currentProjectId = viewModel.currentProjectId,
                            onLoadProject = { project ->
                                viewModel.loadProject(project) {
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
                                }
                                }
                            },
                            onNewProject = {
                                viewModel.newProject() {
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
                                }
                                }
                            },
                            onDeleteProject = { id, onCommitted -> viewModel.moveProjectToTrash(id, onCommitted) },
                            onRestoreProject = { viewModel.restoreTrashedProject(it) },
                            onPermanentlyDeleteProject = { viewModel.permanentlyDeleteTrashedProject(it) },
                            onPurgeExpiredTrash = { viewModel.purgeExpiredTrashedProjects() },
                            onRecordingPurgeIncomplete = viewModel::reportRecordingPurgeFailure,
                            onImportProject = { project ->
                                viewModel.importProject(project) {
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
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
                                viewModel.applyTemplate(name, theme, lyrics) {
                                if (navController.currentDestination?.route == Routes.EDITOR) {
                                    // State update only; keep the existing editor destination alive.
                                } else {
                                    navController.navigate(Routes.EDITOR) {
                                        launchSingleTop = true
                                        popUpTo(Routes.WELCOME) { inclusive = true }
                                    }
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
                            apiKeyPresence = viewModel.apiKeyPresence,
                            currentProvider = viewModel.selectedProvider,
                            currentModel = viewModel.selectedModel,
                            localModelLoading = viewModel.localModelLoading,
                            localModelLoaded = viewModel.localModelLoaded,
                            localModelPath = viewModel.localModelPath,
                            localModelError = viewModel.localModelError,
                            savedLocalModels = viewModel.savedLocalModels,
                            selectedLocalModelId = viewModel.selectedLocalModelId,
                            onApplyAISettings = viewModel::applyAISettings,
                            hasCloudAISharingConsent = viewModel::hasCloudAISharingConsent,
                            onCloudAISharingConsentChange = viewModel::setCloudAISharingConsent,
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
                            verifiedGemmaFileNames = viewModel.verifiedGemmaFileNames,
                            onStartGemmaDownload = { viewModel.startGemmaDownload(it) },
                            onUseDownloadedGemma = { viewModel.useDownloadedGemma(it) },
                            backup = BackupSectionState(
                                status = viewModel.backupStatus,
                                notice = viewModel.backupNotice,
                                busyLabel = viewModel.backupBusyLabel,
                                legacyBackupPresent = viewModel.legacyBackupPresent,
                                migrationInProgress = viewModel.migrationInProgress,
                                migrationError = viewModel.migrationError
                            ),
                            backupActions = remember(viewModel) {
                                BackupSectionActions(
                                    onConnect = viewModel::connectDrive,
                                    onDisconnect = viewModel::disconnectDrive,
                                    onBackUpNow = viewModel::backUpNow,
                                    onRestore = viewModel::restoreFromBackup,
                                    onMigrate = viewModel::migrateLegacyBackup,
                                    exportFileName = viewModel::exportFileName,
                                    onExport = viewModel::exportBackup,
                                    onImport = viewModel::importBackup
                                )
                            },
                            // Editor toggles — each change is persisted via viewModel.persistEditorToggles().
                            useWholeSongContext = viewModel.useWholeSongContext,
                            onWholeSongContextChange = viewModel::saveUseWholeSongContext,
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
