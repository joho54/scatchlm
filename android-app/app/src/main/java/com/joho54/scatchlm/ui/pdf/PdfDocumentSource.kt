package com.joho54.scatchlm.ui.pdf

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.Closeable
import java.io.File

/**
 * 빌트인 PdfRenderer 래퍼. PdfRenderer 는 동시에 한 페이지만 열 수 있어 렌더는 synchronized.
 * iOS PDFKit(PdfViewerView) 의 페이지 렌더 역할.
 */
class PdfDocumentSource(file: File) : Closeable {
    private val fd: ParcelFileDescriptor =
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = PdfRenderer(fd)
    private val lock = Any()

    val pageCount: Int get() = renderer.pageCount

    /** 페이지를 targetWidthPx 너비로 렌더(가로폭 기준 비율 유지). */
    fun renderPage(index: Int, targetWidthPx: Int): Bitmap = synchronized(lock) {
        renderer.openPage(index).use { page ->
            val ratio = page.height.toFloat() / page.width.toFloat()
            val w = targetWidthPx.coerceAtLeast(1)
            val h = (w * ratio).toInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            bitmap
        }
    }

    override fun close() {
        synchronized(lock) {
            runCatching { renderer.close() }
            runCatching { fd.close() }
        }
    }
}
