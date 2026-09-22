package com.rhymeai.app

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.service.AIProvider
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.util.UUID

class ProviderDefaultsInstrumentedTest {
    @Test
    fun freshPreferencesUseLocalAndPreserveExplicitCloudSelection() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<Context>()
        val directory = File(app.cacheDir, "provider-defaults-${UUID.randomUUID()}").apply { mkdirs() }
        val isolatedContext = object : ContextWrapper(app) {
            override fun getApplicationContext(): Context = this
            override fun getFilesDir(): File = directory
        }
        val repo = ProjectRepository(isolatedContext)

        assertEquals("LOCAL", repo.selectedProviderFlow.first())
        assertEquals(AIProvider.LOCAL, AIProvider.entries.first())
        assertEquals(AIProvider.LOCAL, AIProvider.fromName("retired-provider"))

        repo.saveSelectedProvider(AIProvider.CLAUDE.name)
        val reopened = ProjectRepository(isolatedContext)
        assertEquals("CLAUDE", reopened.selectedProviderFlow.first())
    }
}
