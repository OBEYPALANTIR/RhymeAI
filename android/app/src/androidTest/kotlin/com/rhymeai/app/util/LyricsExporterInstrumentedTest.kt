package com.rhymeai.app.util

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class LyricsExporterInstrumentedTest {

    @Test
    fun pdfExportCreatesReadableMultiPageLyricSheet() {
        val lyrics = buildString {
            append("[Verse 1]\n")
            repeat(140) { index ->
                append("  long lyric line ${index + 1} with trailing room   \n")
            }
        }
        val pdfBytes = LyricsExporter.buildPdf(
            SongProject(
                title = "Long Sheet",
                lyrics = lyrics,
                theme = "instrumented pdf export"
            )
        )

        assertTrue(pdfBytes.decodeToString(0, 5) == "%PDF-")
        assertTrue(pdfBytes.decodeToString(pdfBytes.size - 6, pdfBytes.size).contains("EOF"))

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val pdfFile = File.createTempFile("lyrics-export", ".pdf", context.cacheDir)
        pdfFile.writeBytes(pdfBytes)

        ParcelFileDescriptor.open(pdfFile, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                assertTrue("Long lyric export should paginate", renderer.pageCount > 1)
                renderer.openPage(0).use { page ->
                    val bitmap = Bitmap.createBitmap(page.width, page.height, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    assertTrue("Rendered PDF page should contain visible ink", bitmap.hasVisibleInk())
                    bitmap.recycle()
                }
            }
        }
        pdfFile.delete()
    }

    private fun Bitmap.hasVisibleInk(): Boolean {
        val pixels = IntArray(width * height)
        getPixels(pixels, 0, width, 0, 0, width, height)
        return pixels.count { it != Color.WHITE } > 100
    }
}
