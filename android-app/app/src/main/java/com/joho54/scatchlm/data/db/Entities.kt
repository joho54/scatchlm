package com.joho54.scatchlm.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * iOS GRDB 스키마(DatabaseService.swift v1~v6)를 Room 으로 1:1 이식.
 * 날짜는 epoch millis(Long)로 저장. drawing_data 는 Ink 직렬화 BLOB(iOS PKDrawing 과 비호환, 로컬 전용).
 */

@Entity(tableName = "notes")
data class NoteEntity(
    @PrimaryKey val id: String,
    val title: String,
    val language: String = "en",
    val textbookId: String? = null,
    val textbookName: String? = null,
    val textbookPages: Int = 0,
    val drawingData: ByteArray? = null, // 레거시(page 0). NotePage 로 대체됨
    val lastPage: Int = 1,
    val pdfOpen: Boolean = false,
    val currentPageIndex: Int = 0,
    val createdAt: Long,
    val updatedAt: Long,
) {
    override fun equals(other: Any?) = this === other || (other is NoteEntity && other.id == id)
    override fun hashCode() = id.hashCode()
}

@Entity(
    tableName = "note_pages",
    foreignKeys = [ForeignKey(
        entity = NoteEntity::class,
        parentColumns = ["id"],
        childColumns = ["noteId"],
        onDelete = ForeignKey.CASCADE
    )],
    indices = [Index(value = ["noteId", "pageIndex"], unique = true)]
)
data class NotePageEntity(
    @PrimaryKey val id: String,
    val noteId: String,
    val pageIndex: Int,
    val drawingData: ByteArray? = null,
    val createdAt: Long,
) {
    override fun equals(other: Any?) = this === other || (other is NotePageEntity && other.id == id)
    override fun hashCode() = id.hashCode()
}

@Entity(
    tableName = "feedbacks",
    foreignKeys = [ForeignKey(
        entity = NoteEntity::class,
        parentColumns = ["id"],
        childColumns = ["noteId"],
        onDelete = ForeignKey.CASCADE
    )],
    indices = [Index("noteId"), Index("pageId")]
)
data class FeedbackEntity(
    @PrimaryKey val id: String,
    val noteId: String,
    val pageId: String? = null,
    val content: String,            // JSON (AIResponse) 또는 plain 텍스트
    val positionX: Double,
    val positionY: Double,
    val bboxX: Double,
    val bboxY: Double,
    val bboxWidth: Double,
    val bboxHeight: Double,
    val strokeRangeStart: Int = 0,
    val strokeRangeEnd: Int = 0,
    val createdAt: Long,
    val serverFeedbackId: String? = null,
    val userRating: Int? = null,            // 1 = 👍, -1 = 👎
    val userRatingSyncedAt: Long? = null,
)

@Entity(
    tableName = "feedback_chats",
    foreignKeys = [ForeignKey(
        entity = FeedbackEntity::class,
        parentColumns = ["id"],
        childColumns = ["feedbackId"],
        onDelete = ForeignKey.CASCADE
    )],
    indices = [Index("feedbackId")]
)
data class ChatMessageEntity(
    @PrimaryKey val id: String,
    val feedbackId: String,
    val role: String,               // "user" | "assistant"
    val content: String,
    val createdAt: Long,
    val serverMessageId: String? = null,
    val userRating: Int? = null,
    val userRatingSyncedAt: Long? = null,
)

@Entity(
    tableName = "pdf_drawings",
    indices = [Index(value = ["textbookId", "page"], unique = true)]
)
data class PdfDrawingEntity(
    @PrimaryKey val id: String,     // "{textbookId}_{page}"
    val textbookId: String,
    val page: Int,
    val drawingData: ByteArray,
    val updatedAt: Long,
) {
    override fun equals(other: Any?) = this === other || (other is PdfDrawingEntity && other.id == id)
    override fun hashCode() = id.hashCode()
}
