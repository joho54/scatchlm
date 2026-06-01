package com.joho54.scatchlm.ui.draw

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.Modifier
import androidx.compose.runtime.Composable
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.pointerInput

/**
 * 드로잉 표면. PencilKit(PKCanvasView) 대응 — Compose Canvas + 스타일러스 입력 직접 처리.
 * 좌표는 px (이미지 렌더와 동일 좌표계).
 */
@Composable
fun InkCanvas(
    controller: DrawingController,
    modifier: Modifier = Modifier,
) {
    Canvas(
        modifier = modifier.pointerInput(controller.penOnly) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                // 펜 전용 모드: 스타일러스가 아니면 무시 (iOS .pencilOnly)
                if (controller.penOnly && down.type != PointerType.Stylus) return@awaitEachGesture
                // frozen 영역에서 시작하는 입력 차단
                if (controller.isBlocked(down.position.y)) return@awaitEachGesture

                controller.begin(down.position.x, down.position.y)
                drag(down.id) { change ->
                    controller.extend(change.position.x, change.position.y)
                    change.consume()
                }
                controller.end()
            }
        }
    ) {
        // 저장된 스트로크
        for (stroke in controller.strokes) {
            drawStroke(stroke.xs, stroke.ys, Color(stroke.color), stroke.width, stroke.eraser)
        }
        // 진행 중 스트로크
        if (controller.currentPoints.isNotEmpty()) {
            val xs = FloatArray(controller.currentPoints.size) { controller.currentPoints[it].x }
            val ys = FloatArray(controller.currentPoints.size) { controller.currentPoints[it].y }
            drawStroke(xs, ys, Color(controller.color), controller.strokeWidth, controller.isEraser)
        }
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawStroke(
    xs: FloatArray,
    ys: FloatArray,
    color: Color,
    width: Float,
    eraser: Boolean,
) {
    if (xs.isEmpty()) return
    val drawColor = if (eraser) Color.White else color
    if (xs.size == 1) {
        drawCircle(drawColor, radius = width / 2f, center = Offset(xs[0], ys[0]))
        return
    }
    val path = Path().apply {
        moveTo(xs[0], ys[0])
        for (i in 1 until xs.size) lineTo(xs[i], ys[i])
    }
    drawPath(
        path = path,
        color = drawColor,
        style = Stroke(width = width, cap = StrokeCap.Round, join = StrokeJoin.Round),
    )
}
