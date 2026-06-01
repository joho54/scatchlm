package com.joho54.scatchlm.data.api

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
import okhttp3.MultipartBody
import okhttp3.RequestBody
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Multipart
import retrofit2.http.POST
import retrofit2.http.Part
import retrofit2.http.PartMap
import retrofit2.http.Path
import retrofit2.http.Query

/** Retrofit 인터페이스. 경로는 baseUrl(.../api/) 기준 상대경로. */
interface ApiService {

    @Multipart
    @POST("feedback")
    suspend fun feedback(
        @Part image: MultipartBody.Part,
        @PartMap fields: Map<String, @JvmSuppressWildcards RequestBody>,
    ): AIResponseDto

    @POST("feedback/{id}/rate")
    suspend fun rateFeedback(
        @Path("id") feedbackId: String,
        @Body body: RatingRequestDto,
    ): Response<Unit>

    @POST("feedback/chat")
    suspend fun chat(@Body body: ChatRequestDto): ChatResponseDto

    @Multipart
    @POST("pdf/upload")
    suspend fun uploadPdf(
        @Part file: MultipartBody.Part,
        @PartMap fields: Map<String, @JvmSuppressWildcards RequestBody>,
    ): UploadResponseDto

    @GET("pdf/textbooks")
    suspend fun textbooks(): List<TextbookDto>

    @GET("pdf/{id}/chapters")
    suspend fun chapters(@Path("id") textbookId: String): List<ChapterDto>

    @GET("pdf/{id}/guide")
    suspend fun pageGuide(
        @Path("id") textbookId: String,
        @Query("page") page: Int,
        @Query("response_language") responseLanguage: String,
    ): PageGuideDto

    @GET("pdf/{id}/chapter-guide")
    suspend fun chapterGuide(
        @Path("id") textbookId: String,
        @Query("chapter_id") chapterId: String,
        @Query("response_language") responseLanguage: String,
    ): ChapterGuideDto

    @POST("dev/log/batch")
    suspend fun logBatch(@Body body: LogBatchDto): Response<Unit>
}
