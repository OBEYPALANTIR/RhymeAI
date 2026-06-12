package com.rhymeai.app.util

import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.TextPaint
import com.rhymeai.app.data.model.SongProject
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream

object LyricsExporter {
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
    }

    fun buildTxt(project: SongProject): ByteArray {
        val title = project.title.ifBlank { "Untitled" }
        val theme = project.theme.takeIf { it.isNotBlank() }
        val header = buildString {
            append(title)
            if (theme != null) append("\nTheme: ").append(theme)
            append("\n\n")
        }
        return (header + project.lyrics).toByteArray(Charsets.UTF_8)
    }

    fun buildJson(project: SongProject): ByteArray {
        return json.encodeToString(SongProject.serializer(), project).toByteArray(Charsets.UTF_8)
    }

    fun buildLrc(project: SongProject): ByteArray {
        val title = project.title.ifBlank { "Untitled" }
        val sb = StringBuilder()
        sb.append("[ti:").append(title).append("]\n")
        sb.append("[ar:Unknown]\n")
        sb.append("[al:RhymeAI]\n")
        sb.append("[length:00:00.00]\n\n")
        for (raw in project.lyrics.lines()) {
            val line = raw.trimEnd()
            if (line.isEmpty()) {
                sb.append("\n")
            } else {
                sb.append("[00:00.00]").append(line).append("\n")
            }
        }
        return sb.toString().toByteArray(Charsets.UTF_8)
    }

    fun buildPdf(project: SongProject): ByteArray {
        val pageWidth = 612   // 8.5" * 72 dpi
        val pageHeight = 792  // 11"  * 72 dpi
        val marginX = 54f
        val marginY = 54f
        val maxLineWidth = pageWidth - marginX * 2

        val titlePaint = TextPaint().apply {
            isAntiAlias = true
            textSize = 22f
            typeface = Typeface.create(Typeface.SERIF, Typeface.BOLD)
            color = 0xFF111111.toInt()
        }
        val themePaint = TextPaint().apply {
            isAntiAlias = true
            textSize = 11f
            typeface = Typeface.create(Typeface.SERIF, Typeface.ITALIC)
            color = 0xFF666666.toInt()
        }
        val bodyPaint = TextPaint().apply {
            isAntiAlias = true
            textSize = 12f
            typeface = Typeface.create(Typeface.SERIF, Typeface.NORMAL)
            color = 0xFF111111.toInt()
        }
        val sectionPaint = TextPaint(bodyPaint).apply {
            typeface = Typeface.create(Typeface.SERIF, Typeface.BOLD)
            color = 0xFF333333.toInt()
        }
        val lineHeight = 18f
        val titleHeight = 32f

        val doc = PdfDocument()
        try {
            var pageNumber = 1
            var page = doc.startPage(
                PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNumber).create()
            )
            var canvas = page.canvas
            var y = marginY + titleHeight

            fun startNewPage() {
                doc.finishPage(page)
                pageNumber++
                page = doc.startPage(
                    PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNumber).create()
                )
                canvas = page.canvas
                y = marginY + lineHeight
            }

            canvas.drawText(project.title.ifBlank { "Untitled" }, marginX, y, titlePaint)
            y += 8f
            if (project.theme.isNotBlank()) {
                y += lineHeight
                var themeY = y
                for (row in wrapLine("Theme: ${project.theme}", maxLineWidth, themePaint::measureText)) {
                    canvas.drawText(row, marginX, themeY, themePaint)
                    themeY += lineHeight - 4f
                }
                y += lineHeight
            }
            y += lineHeight

            for (raw in project.lyrics.lines()) {
                val line = raw.trimEnd()
                if (line.isEmpty()) {
                    if (y > pageHeight - marginY) startNewPage()
                    y += lineHeight
                    continue
                }
                val paint = if (line.startsWith("[") && line.endsWith("]")) sectionPaint else bodyPaint
                // Page-break per wrapped row, not per logical line, so a long line
                // that wraps near the bottom margin continues on the next page
                // instead of being clipped.
                for (row in wrapLine(line, maxLineWidth, paint::measureText)) {
                    if (y > pageHeight - marginY) startNewPage()
                    canvas.drawText(row, marginX, y, paint)
                    y += lineHeight
                }
            }
            doc.finishPage(page)

            val out = ByteArrayOutputStream()
            doc.writeTo(out)
            return out.toByteArray()
        } finally {
            doc.close()
        }
    }

    // Pure so the row-splitting math is unit-testable without Android's Paint.
    internal fun wrapLine(text: String, maxWidth: Float, measure: (String) -> Float): List<String> {
        if (measure(text) <= maxWidth) return listOf(text)
        val rows = mutableListOf<String>()
        var remaining = text
        while (remaining.isNotEmpty()) {
            var take = 0
            while (take < remaining.length && measure(remaining.substring(0, take + 1)) <= maxWidth) {
                take++
            }
            // Nothing fits (single glyph wider than the page): emit the rest
            // as one overflowing row rather than loop forever.
            if (take <= 0) take = remaining.length
            if (take < remaining.length) {
                val space = remaining.lastIndexOf(' ', take - 1)
                if (space > 0) take = space
            }
            rows.add(remaining.substring(0, take))
            remaining = if (take < remaining.length) remaining.substring(take).trimStart() else ""
        }
        return rows
    }
}
