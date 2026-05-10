package com.rhymeai.app.util

import android.graphics.Paint
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

            canvas.drawText(project.title.ifBlank { "Untitled" }, marginX, y, titlePaint)
            y += 8f
            if (project.theme.isNotBlank()) {
                y += lineHeight
                drawWrapped(
                    canvas = canvas,
                    text = "Theme: ${project.theme}",
                    x = marginX,
                    yStart = y,
                    paint = themePaint,
                    maxWidth = maxLineWidth,
                    lineHeight = lineHeight - 4f
                )
                y += lineHeight
            }
            y += lineHeight

            for (raw in project.lyrics.lines()) {
                val line = raw.trimEnd()
                if (y > pageHeight - marginY) {
                    doc.finishPage(page)
                    pageNumber++
                    page = doc.startPage(
                        PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNumber).create()
                    )
                    canvas = page.canvas
                    y = marginY + lineHeight
                }
                if (line.isEmpty()) {
                    y += lineHeight
                    continue
                }
                val paint = if (line.startsWith("[") && line.endsWith("]")) sectionPaint else bodyPaint
                val consumedLines = drawWrapped(
                    canvas = canvas,
                    text = line,
                    x = marginX,
                    yStart = y,
                    paint = paint,
                    maxWidth = maxLineWidth,
                    lineHeight = lineHeight
                )
                y += lineHeight * consumedLines
            }
            doc.finishPage(page)

            val out = ByteArrayOutputStream()
            doc.writeTo(out)
            return out.toByteArray()
        } finally {
            doc.close()
        }
    }

    private fun drawWrapped(
        canvas: android.graphics.Canvas,
        text: String,
        x: Float,
        yStart: Float,
        paint: Paint,
        maxWidth: Float,
        lineHeight: Float
    ): Int {
        if (paint.measureText(text) <= maxWidth) {
            canvas.drawText(text, x, yStart, paint)
            return 1
        }
        var lines = 0
        var remaining = text
        var y = yStart
        while (remaining.isNotEmpty()) {
            var take = paint.breakText(remaining, true, maxWidth, null)
            if (take <= 0) take = remaining.length
            if (take < remaining.length) {
                val space = remaining.lastIndexOf(' ', take - 1)
                if (space > 0) take = space
            }
            val chunk = remaining.substring(0, take)
            canvas.drawText(chunk, x, y, paint)
            y += lineHeight
            lines++
            remaining = if (take < remaining.length) remaining.substring(take).trimStart() else ""
        }
        return lines
    }
}
