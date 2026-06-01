package com.joho54.scatchlm.ui.draw

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset

/**
 * 드로잉 상태 홀더. iOS NoteView 의 PKCanvasView + Coordinator 의 스트로크 관리/frozen 로직 대응.
 */
class DrawingController {
    val strokes = mutableStateListOf<StrokeData>()
    val currentPoints = mutableStateListOf<Offset>()
    private val redoStack = ArrayDeque<StrokeData>()

    var color by mutableStateOf(0xFF000000L)
    var strokeWidth by mutableFloatStateOf(4f)
    var isEraser by mutableStateOf(false)
    var penOnly by mutableStateOf(true)

    /** 이 인덱스 이전 스트로크는 피드백 완료(frozen). */
    var frozenEndIndex by mutableIntStateOf(0)
        private set

    /** 이 Y 아래(작은 값=위쪽)는 frozen 영역 — 새 스트로크 차단. */
    var frozenBottomY by mutableFloatStateOf(0f)
        private set

    val strokeCount: Int get() = strokes.size

    /** frozen 영역에서 시작하는지 — true 면 입력 무시. */
    fun isBlocked(startY: Float): Boolean = startY < frozenBottomY

    fun begin(x: Float, y: Float) {
        currentPoints.clear()
        currentPoints.add(Offset(x, y))
    }

    fun extend(x: Float, y: Float) {
        currentPoints.add(Offset(x, y))
    }

    fun end() {
        if (currentPoints.size >= 1) {
            strokes.add(
                StrokeData(
                    xs = currentPoints.map { it.x }.toFloatArray(),
                    ys = currentPoints.map { it.y }.toFloatArray(),
                    color = color,
                    width = strokeWidth,
                    eraser = isEraser,
                )
            )
            redoStack.clear()
        }
        currentPoints.clear()
    }

    fun undo() {
        if (strokes.size > frozenEndIndex) {
            redoStack.addLast(strokes.removeAt(strokes.lastIndex))
        }
    }

    fun redo() {
        redoStack.removeLastOrNull()?.let { strokes.add(it) }
    }

    /** 피드백 요청 후: 현재까지를 frozen 처리. */
    fun freeze(bottomY: Float) {
        frozenEndIndex = strokes.size
        frozenBottomY = maxOf(frozenBottomY, bottomY)
    }

    /** 새 스트로크만(frozen 이후) 반환 — 피드백 이미지 캡처용. */
    fun newStrokes(): List<StrokeData> =
        if (frozenEndIndex < strokes.size) strokes.subList(frozenEndIndex, strokes.size).toList()
        else emptyList()

    fun load(data: DrawingData) {
        strokes.clear()
        strokes.addAll(data.strokes)
        redoStack.clear()
        frozenEndIndex = 0
        frozenBottomY = 0f
        currentPoints.clear()
    }

    fun export(): DrawingData = DrawingData(strokes.toList())

    fun resetFrozen() {
        frozenEndIndex = 0
        frozenBottomY = 0f
    }
}
