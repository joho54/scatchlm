package com.joho54.scatchlm.data.db

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface NoteDao {
    @Query("SELECT * FROM notes ORDER BY updatedAt DESC")
    fun observeAll(): Flow<List<NoteEntity>>

    @Query("SELECT * FROM notes ORDER BY updatedAt DESC")
    suspend fun allNotes(): List<NoteEntity>

    @Query("SELECT * FROM notes WHERE id = :id")
    suspend fun note(id: String): NoteEntity?

    @Upsert
    suspend fun save(note: NoteEntity)

    @Query("DELETE FROM notes WHERE id = :id")
    suspend fun delete(id: String)

    @Query("UPDATE notes SET drawingData = :data, updatedAt = :ts WHERE id = :id")
    suspend fun updateDrawingData(id: String, data: ByteArray?, ts: Long)

    @Query("UPDATE notes SET lastPage = :page, updatedAt = :ts WHERE id = :id")
    suspend fun updateLastPage(id: String, page: Int, ts: Long)

    @Query("UPDATE notes SET pdfOpen = :open, updatedAt = :ts WHERE id = :id")
    suspend fun updatePdfOpen(id: String, open: Boolean, ts: Long)

    @Query("UPDATE notes SET currentPageIndex = :index, updatedAt = :ts WHERE id = :id")
    suspend fun updateCurrentPageIndex(id: String, index: Int, ts: Long)

    @Query(
        "UPDATE notes SET textbookId = :textbookId, textbookName = :name, " +
            "textbookPages = :pages, updatedAt = :ts WHERE id = :id"
    )
    suspend fun linkTextbook(id: String, textbookId: String, name: String, pages: Int, ts: Long)
}

@Dao
interface NotePageDao {
    @Query("SELECT * FROM note_pages WHERE noteId = :noteId ORDER BY pageIndex ASC")
    suspend fun pages(noteId: String): List<NotePageEntity>

    @Query("SELECT * FROM note_pages WHERE noteId = :noteId AND pageIndex = :pageIndex LIMIT 1")
    suspend fun page(noteId: String, pageIndex: Int): NotePageEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(page: NotePageEntity)

    @Query("UPDATE note_pages SET drawingData = :data WHERE id = :id")
    suspend fun saveDrawing(id: String, data: ByteArray?)
}

@Dao
interface FeedbackDao {
    @Query("SELECT * FROM feedbacks WHERE noteId = :noteId ORDER BY createdAt ASC")
    suspend fun byNote(noteId: String): List<FeedbackEntity>

    @Query("SELECT * FROM feedbacks WHERE pageId = :pageId ORDER BY createdAt ASC")
    suspend fun byPage(pageId: String): List<FeedbackEntity>

    @Upsert
    suspend fun save(feedback: FeedbackEntity)

    @Query("DELETE FROM feedbacks WHERE id = :id")
    suspend fun delete(id: String)

    @Query("UPDATE feedbacks SET userRating = :rating, userRatingSyncedAt = :syncedAt WHERE id = :id")
    suspend fun updateRating(id: String, rating: Int?, syncedAt: Long?)
}

@Dao
interface ChatMessageDao {
    @Query("SELECT * FROM feedback_chats WHERE feedbackId = :feedbackId ORDER BY createdAt ASC")
    suspend fun byFeedback(feedbackId: String): List<ChatMessageEntity>

    @Upsert
    suspend fun save(message: ChatMessageEntity)

    @Query("UPDATE feedback_chats SET userRating = :rating, userRatingSyncedAt = :syncedAt WHERE id = :id")
    suspend fun updateRating(id: String, rating: Int?, syncedAt: Long?)
}

@Dao
interface PdfDrawingDao {
    @Query("SELECT * FROM pdf_drawings WHERE textbookId = :textbookId AND page = :page LIMIT 1")
    suspend fun drawing(textbookId: String, page: Int): PdfDrawingEntity?

    @Upsert
    suspend fun save(drawing: PdfDrawingEntity)
}
