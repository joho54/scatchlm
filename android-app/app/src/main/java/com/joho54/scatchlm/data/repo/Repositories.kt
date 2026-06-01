package com.joho54.scatchlm.data.repo

import com.joho54.scatchlm.data.api.ApiClient
import com.joho54.scatchlm.data.api.dto.AIResponseDto
import com.joho54.scatchlm.data.api.dto.ChapterDto
import com.joho54.scatchlm.data.api.dto.ChapterGuideDto
import com.joho54.scatchlm.data.api.dto.ChatRequestDto
import com.joho54.scatchlm.data.api.dto.ChatResponseDto
import com.joho54.scatchlm.data.api.dto.PageGuideDto
import com.joho54.scatchlm.data.api.dto.RatingRequestDto
import com.joho54.scatchlm.data.api.dto.TextbookDto
import com.joho54.scatchlm.data.api.dto.UploadResponseDto
import com.joho54.scatchlm.data.db.AppDatabase
import com.joho54.scatchlm.data.db.ChatMessageEntity
import com.joho54.scatchlm.data.db.FeedbackEntity
import com.joho54.scatchlm.data.db.NoteEntity
import com.joho54.scatchlm.data.db.NotePageEntity
import com.joho54.scatchlm.data.db.PdfDrawingEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

private fun now() = System.currentTimeMillis()
private fun uuid() = UUID.randomUUID().toString()

class NoteRepository(private val db: AppDatabase) {
    private val notes = db.noteDao()
    private val pages = db.notePageDao()

    fun observeNotes(): Flow<List<NoteEntity>> = notes.observeAll()
    suspend fun getNote(id: String) = notes.note(id)

    suspend fun createNote(title: String, language: String): NoteEntity {
        val ts = now()
        val note = NoteEntity(
            id = uuid(), title = title, language = language,
            createdAt = ts, updatedAt = ts
        )
        notes.save(note)
        // page 0 생성 (iOS v3 마이그레이션과 동일하게 항상 최소 1페이지)
        pages.insert(NotePageEntity(id = uuid(), noteId = note.id, pageIndex = 0, createdAt = ts))
        return note
    }

    suspend fun saveNote(note: NoteEntity) = notes.save(note.copy(updatedAt = now()))
    suspend fun deleteNote(id: String) = notes.delete(id)  // FK CASCADE → pages/feedbacks 삭제
    suspend fun updateLastPage(id: String, page: Int) = notes.updateLastPage(id, page, now())
    suspend fun updatePdfOpen(id: String, open: Boolean) = notes.updatePdfOpen(id, open, now())
    suspend fun updateCurrentPageIndex(id: String, index: Int) =
        notes.updateCurrentPageIndex(id, index, now())

    suspend fun linkTextbook(id: String, textbookId: String, name: String, pages: Int) =
        notes.linkTextbook(id, textbookId, name, pages, now())

    suspend fun pages(noteId: String): List<NotePageEntity> {
        val existing = pages.pages(noteId)
        if (existing.isNotEmpty()) return existing
        val page = NotePageEntity(id = uuid(), noteId = noteId, pageIndex = 0, createdAt = now())
        pages.insert(page)
        return listOf(page)
    }

    suspend fun page(noteId: String, pageIndex: Int) = pages.page(noteId, pageIndex)

    suspend fun createPage(noteId: String, pageIndex: Int): NotePageEntity {
        val page = NotePageEntity(id = uuid(), noteId = noteId, pageIndex = pageIndex, createdAt = now())
        pages.insert(page)
        return page
    }

    suspend fun savePageDrawing(pageId: String, data: ByteArray?) = pages.saveDrawing(pageId, data)
}

class FeedbackRepository(private val db: AppDatabase, private val api: ApiClient) {
    private val feedbacks = db.feedbackDao()
    private val chats = db.chatMessageDao()

    suspend fun byNote(noteId: String) = feedbacks.byNote(noteId)
    suspend fun byPage(pageId: String) = feedbacks.byPage(pageId)
    suspend fun saveFeedback(feedback: FeedbackEntity) = feedbacks.save(feedback)
    suspend fun deleteFeedback(id: String) = feedbacks.delete(id)

    suspend fun requestFeedback(imageBytes: ByteArray, fields: Map<String, String>): AIResponseDto =
        api.postFeedback(imageBytes, fields)

    /** 평가: 로컬 즉시 반영 + 서버 전송. 서버 성공 시 syncedAt 기록. */
    suspend fun rateFeedback(localId: String, serverFeedbackId: String?, rating: Int, tags: List<String>, comment: String?) {
        feedbacks.updateRating(localId, rating, null)
        if (serverFeedbackId != null) {
            runCatching { api.rateFeedback(serverFeedbackId, RatingRequestDto(rating, tags, comment)) }
                .onSuccess { feedbacks.updateRating(localId, rating, now()) }
        }
    }

    suspend fun chatMessages(feedbackId: String) = chats.byFeedback(feedbackId)
    suspend fun saveChatMessage(message: ChatMessageEntity) = chats.save(message)
    suspend fun chat(req: ChatRequestDto): ChatResponseDto = api.chat(req)
    suspend fun rateChatMessage(id: String, rating: Int) = chats.updateRating(id, rating, now())
}

class PdfRepository(
    private val db: AppDatabase,
    private val api: ApiClient,
    private val cacheDir: File,
) {
    private val drawings = db.pdfDrawingDao()

    suspend fun textbooks(): List<TextbookDto> = api.textbooks()
    suspend fun uploadPdf(file: File, noteId: String?): UploadResponseDto = api.uploadPdf(file, noteId)
    suspend fun chapters(textbookId: String): List<ChapterDto> = api.chapters(textbookId)
    suspend fun pageGuide(textbookId: String, page: Int, lang: String): PageGuideDto =
        api.pageGuide(textbookId, page, lang)
    suspend fun chapterGuide(textbookId: String, chapterId: String, lang: String): ChapterGuideDto =
        api.chapterGuide(textbookId, chapterId, lang)

    /** 캐시에 없으면 다운로드 후 캐시 파일 반환. iOS cacheDir/pdf_<id>.pdf 대응. */
    suspend fun cachedPdf(textbookId: String): File = withContext(Dispatchers.IO) {
        val dest = File(cacheDir, "pdf_$textbookId.pdf")
        if (!dest.exists() || dest.length() == 0L) api.downloadPdf(textbookId, dest)
        dest
    }

    suspend fun pdfDrawing(textbookId: String, page: Int) = drawings.drawing(textbookId, page)
    suspend fun savePdfDrawing(textbookId: String, page: Int, data: ByteArray) =
        drawings.save(PdfDrawingEntity("${textbookId}_$page", textbookId, page, data, now()))
}
