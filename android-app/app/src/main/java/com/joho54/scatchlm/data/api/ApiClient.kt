package com.joho54.scatchlm.data.api

import com.joho54.scatchlm.Config
import com.joho54.scatchlm.data.api.dto.AIResponseDto
import com.joho54.scatchlm.data.api.dto.ChapterDto
import com.joho54.scatchlm.data.api.dto.ChapterGuideDto
import com.joho54.scatchlm.data.api.dto.ChatRequestDto
import com.joho54.scatchlm.data.api.dto.ChatResponseDto
import com.joho54.scatchlm.data.api.dto.LogBatchDto
import com.joho54.scatchlm.data.api.dto.PageGuideDto
import com.joho54.scatchlm.data.api.dto.RatingRequestDto
import com.joho54.scatchlm.data.api.dto.TextbookDto
import com.joho54.scatchlm.data.api.dto.UploadResponseDto
import com.joho54.scatchlm.data.log.LogService
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * iOS `APIClient.swift` 대응.
 * - Bearer 토큰 자동 첨부(인터셉터)
 * - multipart 피드백/업로드
 * - PDF 다운로드(헤더 못 싣는 렌더러용 ?token= URL 도 제공)
 */
class ApiClient(
    private val authProvider: () -> String?,
    private val log: LogService,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    private val okHttp: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val builder = chain.request().newBuilder()
            authProvider()?.let { builder.header("Authorization", "Bearer $it") }
            chain.proceed(builder.build())
        }
        .build()

    private val service: ApiService = Retrofit.Builder()
        .baseUrl(baseUrlWithSlash())
        .client(okHttp)
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()
        .create(ApiService::class.java)

    private fun baseUrlWithSlash(): String {
        val base = Config.apiBaseUrl
        return if (base.endsWith("/")) base else "$base/"
    }

    // MARK: - Feedback

    /** 캔버스 이미지(JPEG/PNG 바이트) → AI 피드백. base64 아님, multipart 바이너리. */
    suspend fun postFeedback(
        imageBytes: ByteArray,
        fields: Map<String, String>,
        mimeType: String = "image/jpeg",
        fileName: String = "note.jpg",
    ): AIResponseDto {
        val imagePart = MultipartBody.Part.createFormData(
            "image", fileName,
            imageBytes.toRequestBody(mimeType.toMediaTypeOrNull())
        )
        return service.feedback(imagePart, fields.toTextParts())
    }

    suspend fun rateFeedback(feedbackId: String, body: RatingRequestDto) {
        val resp = service.rateFeedback(feedbackId, body)
        if (!resp.isSuccessful) throw IOException("rate failed: ${resp.code()}")
    }

    suspend fun chat(body: ChatRequestDto): ChatResponseDto = service.chat(body)

    // MARK: - PDF

    suspend fun uploadPdf(file: File, noteId: String? = null): UploadResponseDto {
        val filePart = MultipartBody.Part.createFormData(
            "file", file.name,
            file.asRequestBody("application/pdf".toMediaTypeOrNull())
        )
        val fields = buildMap { noteId?.let { put("note_id", it) } }
        return service.uploadPdf(filePart, fields.toTextParts())
    }

    suspend fun textbooks(): List<TextbookDto> = service.textbooks()

    suspend fun chapters(textbookId: String): List<ChapterDto> = service.chapters(textbookId)

    suspend fun pageGuide(textbookId: String, page: Int, responseLanguage: String): PageGuideDto =
        service.pageGuide(textbookId, page, responseLanguage)

    suspend fun chapterGuide(
        textbookId: String,
        chapterId: String,
        responseLanguage: String,
    ): ChapterGuideDto = service.chapterGuide(textbookId, chapterId, responseLanguage)

    /** 헤더를 못 싣는 PDF 뷰어용. iOS PdfViewerView 의 ?token= 패턴 (auth.py:64,70 지원). */
    fun pdfFileUrl(textbookId: String): String {
        val token = authProvider()
        val base = baseUrlWithSlash()
        val url = "${base}pdf/$textbookId/file"
        return if (token != null) "$url?token=$token" else url
    }

    /** PDF 를 캐시 파일로 다운로드. iOS 의 cacheDir/pdf_<id>.pdf 대응. */
    @Throws(IOException::class)
    fun downloadPdf(textbookId: String, dest: File) {
        val request = Request.Builder().url(pdfFileUrl(textbookId)).build()
        okHttp.newCall(request).execute().use { resp ->
            if (!resp.isSuccessful) throw IOException("PDF download failed: ${resp.code}")
            val body = resp.body ?: throw IOException("empty PDF body")
            dest.outputStream().use { out -> body.byteStream().copyTo(out) }
        }
    }

    // MARK: - Logging

    suspend fun postLogBatch(batch: LogBatchDto) {
        runCatching { service.logBatch(batch) }
    }

    private fun Map<String, String>.toTextParts(): Map<String, RequestBody> =
        mapValues { (_, v) -> v.toRequestBody("text/plain".toMediaTypeOrNull()) }
}
