package com.joho54.scatchlm.ui.draw

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * 드로잉 직렬화 모델. iOS PKDrawing.dataRepresentation() 대응이나 포맷은 자체 정의(JSON BLOB).
 * 로컬 전용이라 iOS 와 비호환이어도 무방(스펙 §1.2).
 */
@Serializable
data class StrokeData(
    val xs: FloatArray,
    val ys: FloatArray,
    val color: Long,        // ARGB
    val width: Float,
    val eraser: Boolean = false,
) {
    override fun equals(other: Any?) = this === other
    override fun hashCode() = System.identityHashCode(this)
}

@Serializable
data class DrawingData(
    val strokes: List<StrokeData> = emptyList(),
)

object DrawingCodec {
    private val json = Json { ignoreUnknownKeys = true }

    fun encode(data: DrawingData): ByteArray =
        json.encodeToString(DrawingData.serializer(), data).toByteArray(Charsets.UTF_8)

    fun decode(bytes: ByteArray?): DrawingData {
        if (bytes == null || bytes.isEmpty()) return DrawingData()
        return runCatching {
            json.decodeFromString(DrawingData.serializer(), String(bytes, Charsets.UTF_8))
        }.getOrDefault(DrawingData())
    }
}
