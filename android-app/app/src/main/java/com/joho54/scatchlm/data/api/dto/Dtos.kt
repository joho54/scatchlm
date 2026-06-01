package com.joho54.scatchlm.data.api.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/* ── 피드백 (snake_case) ───────────────────────────────────────────── */

@Serializable
data class AIResponseDto(
    val type: String = "feedback",
    val content: String = "",
    @SerialName("feedback_id") val feedbackId: String? = null,
    @SerialName("recognized_text") val recognizedText: String = "",
    val feedback: String = "",
    val summary: String = "",
) {
    /** iOS AIResponse.displayText 대응 */
    val displayText: String
        get() = when {
            content.isNotBlank() -> content
            else -> buildString {
                if (recognizedText.isNotBlank()) append("📝 $recognizedText\n\n")
                if (feedback.isNotBlank()) append("$feedback\n\n")
                if (summary.isNotBlank()) append("💡 $summary")
            }.trim()
        }
}

/* ── 채팅 (요청 snake_case) ────────────────────────────────────────── */

@Serializable
data class ChatMessageDto(
    val role: String,
    val content: String,
)

@Serializable
data class ChatRequestDto(
    val message: String,
    val history: List<ChatMessageDto> = emptyList(),
    @SerialName("response_language") val responseLanguage: String = "Korean",
    @SerialName("textbook_id") val textbookId: String? = null,
    @SerialName("current_page") val currentPage: Int? = null,
    @SerialName("note_id") val noteId: String? = null,
    @SerialName("parent_feedback_id") val parentFeedbackId: String? = null,
)

@Serializable
data class ChatResponseDto(
    val content: String,
    val sources: List<ChatSourceDto> = emptyList(),
    @SerialName("feedback_id") val feedbackId: String? = null,
)

@Serializable
data class ChatSourceDto(
    @SerialName("page_start") val pageStart: Int? = null,
    @SerialName("page_end") val pageEnd: Int? = null,
    val preview: String? = null,
)

/* ── 평가 (snake_case) ─────────────────────────────────────────────── */

@Serializable
data class RatingRequestDto(
    val rating: Int,
    @SerialName("reason_tags") val reasonTags: List<String> = emptyList(),
    val comment: String? = null,
    @SerialName("client_ts") val clientTs: String? = null,
)

/* ── PDF / 교재 (camelCase) ────────────────────────────────────────── */

@Serializable
data class TextbookDto(
    val id: String,
    val fileName: String,
    val totalPages: Int = 0,
    val fileSize: Long = 0,
    val createdAt: String? = null,
)

@Serializable
data class UploadResponseDto(
    val id: String,
    val fileName: String,
    val totalPages: Int = 0,
    val fileSize: Long = 0,
    val chapters: Int = 0,
    val indexing: String? = null,
)

@Serializable
data class ChapterDto(
    val id: String,
    val level: Int,
    val title: String,
    val pageStart: Int,
    val pageEnd: Int,
)

/* ── 학습 가이드 (snake_case) ──────────────────────────────────────── */

@Serializable
data class PageGuideDto(
    val page: Int,
    val topic: String = "",
    val content: String = "",
    @SerialName("key_points") val keyPoints: List<String> = emptyList(),
    val exercises: List<String> = emptyList(),
    val connections: String = "",
    val cached: Boolean = false,
    @SerialName("feedback_id") val feedbackId: String? = null,
)

@Serializable
data class ChapterGuideDto(
    @SerialName("chapter_id") val chapterId: String,
    val title: String,
    @SerialName("page_start") val pageStart: Int = 0,
    @SerialName("page_end") val pageEnd: Int = 0,
    val topic: String = "",
    @SerialName("key_concepts") val keyConcepts: List<String> = emptyList(),
    @SerialName("study_order") val studyOrder: List<String> = emptyList(),
    @SerialName("common_mistakes") val commonMistakes: List<String> = emptyList(),
    val summary: String = "",
    val cached: Boolean = false,
    @SerialName("feedback_id") val feedbackId: String? = null,
)

/* ── 로그 ──────────────────────────────────────────────────────────── */

@Serializable
data class LogEntryDto(
    val level: String = "info",
    val tag: String = "",
    val message: String,
    val timestamp: String? = null,
)

@Serializable
data class LogBatchDto(
    val logs: List<LogEntryDto>,
)
