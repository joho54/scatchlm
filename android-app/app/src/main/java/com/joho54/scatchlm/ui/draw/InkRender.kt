package com.joho54.scatchlm.ui.draw

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import java.io.ByteArrayOutputStream

/** 스트로크 묶음의 캔버스 좌표 바운딩 박스. */
data class StrokeBounds(val minX: Float, val minY: Float, val maxX: Float, val maxY: Float) {
    val width get() = maxX - minX
    val height get() = maxY - minY
}

object InkRender {
    private const val MAX_DIM = 2000      // iOS: 최대 2000px
    private const val JPEG_QUALITY = 80   // iOS: 0.8
    private const val PADDING = 24f

    fun bounds(strokes: List<StrokeData>): StrokeBounds? {
        if (strokes.isEmpty()) return null
        var minX = Float.MAX_VALUE; var minY = Float.MAX_VALUE
        var maxX = -Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
        for (s in strokes) {
            for (i in s.xs.indices) {
                minX = minOf(minX, s.xs[i]); maxX = maxOf(maxX, s.xs[i])
                minY = minOf(minY, s.ys[i]); maxY = maxOf(maxY, s.ys[i])
            }
        }
        return StrokeBounds(minX - PADDING, minY - PADDING, maxX + PADDING, maxY + PADDING)
    }

    /**
     * 스트로크를 JPEG 로 렌더. iOS requestFeedback 이미지 파이프라인 대응.
     * @return JPEG 바이트와 캔버스 좌표 bbox. 스트로크 없으면 null.
     */
    fun renderToJpeg(strokes: List<StrokeData>, darkInvert: Boolean = false): Pair<ByteArray, StrokeBounds>? {
        val b = bounds(strokes) ?: return null
        val w = b.width.coerceAtLeast(1f)
        val h = b.height.coerceAtLeast(1f)
        val scale = minOf(1f, MAX_DIM / maxOf(w, h))
        val bw = (w * scale).toInt().coerceAtLeast(1)
        val bh = (h * scale).toInt().coerceAtLeast(1)

        val bitmap = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(if (darkInvert) Color.BLACK else Color.WHITE)
        canvas.scale(scale, scale)
        canvas.translate(-b.minX, -b.minY)

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        for (s in strokes) {
            paint.color = if (s.eraser) {
                if (darkInvert) Color.BLACK else Color.WHITE
            } else if (darkInvert) invert(s.color.toInt()) else s.color.toInt()
            paint.strokeWidth = s.width
            drawStrokePath(canvas, s, paint)
        }

        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
        bitmap.recycle()
        return out.toByteArray() to b
    }

    /** HomeScreen 노트 카드 썸네일. 전체 드로잉을 targetPx 폭으로 렌더. */
    fun renderThumbnail(strokes: List<StrokeData>, targetPx: Int = 300): Bitmap? {
        val b = bounds(strokes) ?: return null
        val w = b.width.coerceAtLeast(1f); val h = b.height.coerceAtLeast(1f)
        val scale = targetPx / maxOf(w, h)
        val bw = (w * scale).toInt().coerceAtLeast(1); val bh = (h * scale).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        canvas.scale(scale, scale)
        canvas.translate(-b.minX, -b.minY)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
        }
        for (s in strokes) {
            paint.color = if (s.eraser) Color.WHITE else s.color.toInt()
            paint.strokeWidth = s.width
            drawStrokePath(canvas, s, paint)
        }
        return bitmap
    }

    private fun drawStrokePath(canvas: Canvas, s: StrokeData, paint: Paint) {
        if (s.xs.isEmpty()) return
        if (s.xs.size == 1) {
            canvas.drawPoint(s.xs[0], s.ys[0], paint.apply { style = Paint.Style.FILL })
            paint.style = Paint.Style.STROKE
            return
        }
        val path = Path().apply {
            moveTo(s.xs[0], s.ys[0])
            for (i in 1 until s.xs.size) lineTo(s.xs[i], s.ys[i])
        }
        canvas.drawPath(path, paint)
    }

    private fun invert(argb: Int): Int {
        val a = (argb ushr 24) and 0xFF
        val r = 255 - ((argb ushr 16) and 0xFF)
        val g = 255 - ((argb ushr 8) and 0xFF)
        val bch = 255 - (argb and 0xFF)
        return (a shl 24) or (r shl 16) or (g shl 8) or bch
    }
}
