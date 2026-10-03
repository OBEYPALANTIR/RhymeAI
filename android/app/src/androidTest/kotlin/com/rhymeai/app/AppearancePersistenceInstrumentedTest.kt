package com.rhymeai.app

import android.app.Application
import androidx.compose.ui.graphics.toArgb
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.data.model.AnalysisPresentation
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.ui.theme.PaperWhite
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppearancePersistenceInstrumentedTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val repo = ProjectRepository(app)

    @Before
    fun setUp() = runBlocking {
        repo.saveAppearance(AppAppearance.INK)
        repo.saveAnalysisPresentation(AnalysisPresentation.COLOR)
    }

    @After
    fun tearDown() = runBlocking {
        repo.saveAppearance(AppAppearance.INK)
        repo.saveAnalysisPresentation(AnalysisPresentation.COLOR)
    }

    @Test
    fun savesAndRestoresEveryAppearance() = runBlocking {
        AppAppearance.entries.forEach { appearance ->
            repo.saveAppearance(appearance)

            assertEquals(appearance, repo.appearanceFlow.first())
        }
    }

    @Test
    fun startupSurfaceUsesTheInkPaperColor() {
        assertEquals(PaperWhite.toArgb(), app.getColor(R.color.splash_material_surface))
    }

    @Test
    fun analysisPresentationPersistsAndUnknownFallsBackToColor() = runBlocking {
        AnalysisPresentation.entries.forEach { value ->
            repo.saveAnalysisPresentation(value)
            assertEquals(value, repo.analysisPresentationFlow.first())
        }
    }
}
