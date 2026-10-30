package com.rhymeai.app.util

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import org.junit.Assert.assertEquals
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

    @Test
    fun pdfExportStartsLyricsBelowAWrappedTheme() {
        val theme = buildString { repeat(12) { append("a theme sentence that wraps across several rows of the page ") } }
        val lyrics = (1..6).joinToString("\n") { "lyric line $it" }
        val themeOnly = renderFirstPage(SongProject(title = "Wrapped", lyrics = "", theme = theme))
        val combined = renderFirstPage(SongProject(title = "Wrapped", lyrics = lyrics, theme = theme))
        val themeBottom = themeOnly.lastInkRow()

        // Above the theme's last row the two renders must be pixel-identical; any
        // difference there is lyric ink drawn over the theme.
        assertTrue("theme-only render should have ink", themeBottom > 0)
        assertEquals(
            "Lyric ink overlaps the wrapped theme",
            themeOnly.inkCount(untilRow = themeBottom),
            combined.inkCount(untilRow = themeBottom)
        )
        assertTrue("lyrics should still render", combined.inkCount(untilRow = combined.height) > themeOnly.inkCount(untilRow = themeOnly.height))
        themeOnly.recycle()
        combined.recycle()
    }

    private fun renderFirstPage(project: SongProject): Bitmap {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val pdfFile = File.createTempFile("lyrics-export", ".pdf", context.cacheDir)
        pdfFile.writeBytes(LyricsExporter.buildPdf(project))
        try {
            ParcelFileDescriptor.open(pdfFile, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    renderer.openPage(0).use { page ->
                        val bitmap = Bitmap.createBitmap(page.width * 2, page.height * 2, Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        return bitmap
                    }
                }
            }
        } finally {
            pdfFile.delete()
        }
    }

    private fun Bitmap.inkCount(untilRow: Int): Int {
        val pixels = IntArray(width * untilRow)
        getPixels(pixels, 0, width, 0, 0, width, untilRow)
        return pixels.count { it != Color.WHITE }
    }

    private fun Bitmap.lastInkRow(): Int {
        val pixels = IntArray(width * height)
        getPixels(pixels, 0, width, 0, 0, width, height)
        for (row in height - 1 downTo 0) {
            if ((0 until width).any { pixels[row * width + it] != Color.WHITE }) return row + 1
        }
        return 0
    }

    private fun Bitmap.hasVisibleInk(): Boolean {
        val pixels = IntArray(width * height)
        getPixels(pixels, 0, width, 0, 0, width, height)
        return pixels.count { it != Color.WHITE } > 100
    }
}
