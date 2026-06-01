package com.joho54.scatchlm.data.auth

import android.content.Context
import com.joho54.scatchlm.Config
import com.joho54.scatchlm.data.log.appLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * iOS `AuthService.swift` 대응. Supabase GoTrue REST API 를 OkHttp 로 직접 호출.
 * 토큰은 Config(SharedPreferences)에 저장. backend 는 동일 Supabase 프로젝트의 JWT(ES256)를
 * JWKS 로 검증한다(auth.py:29-49) — 클라이언트가 토큰을 어떻게 얻든 무관.
 */
class AuthRepository {

    private val json = Json { ignoreUnknownKeys = true }
    private val jsonMedia = "application/json".toMediaType()
    private val http = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val authBase get() = "${Config.supabaseUrl}/auth/v1"

    private val _isAuthenticated = MutableStateFlow(Config.accessToken != null)
    val isAuthenticated: StateFlow<Boolean> = _isAuthenticated.asStateFlow()

    /** 동기 접근(ApiClient 인터셉터용). */
    val accessToken: String? get() = Config.accessToken

    @Serializable
    private data class TokenResponse(
        @SerialName("access_token") val accessToken: String? = null,
        @SerialName("refresh_token") val refreshToken: String? = null,
        val user: UserDto? = null,
    )

    @Serializable
    private data class UserDto(val id: String? = null, val email: String? = null)

    val userId: String? get() = null // 필요 시 JWT 디코딩으로 확장

    /** 앱 시작 시 저장된 refresh token 으로 세션 갱신 시도. */
    fun initialize(context: Context, scope: CoroutineScope) {
        scope.launch {
            val refresh = Config.refreshToken ?: return@launch
            runCatching { refreshSession(refresh) }
                .onFailure { appLog("auth", "refresh failed: ${it.message}") }
        }
    }

    suspend fun signIn(email: String, password: String) = withContext(Dispatchers.IO) {
        val body = json.encodeToString(
            mapOf("email" to email, "password" to password)
        ).toRequestBody(jsonMedia)
        val req = Request.Builder()
            .url("$authBase/token?grant_type=password")
            .header("apikey", Config.supabaseAnonKey)
            .post(body)
            .build()
        store(execute(req))
    }

    suspend fun signUp(email: String, password: String) = withContext(Dispatchers.IO) {
        val body = json.encodeToString(
            mapOf("email" to email, "password" to password)
        ).toRequestBody(jsonMedia)
        val req = Request.Builder()
            .url("$authBase/signup")
            .header("apikey", Config.supabaseAnonKey)
            .post(body)
            .build()
        val token = execute(req)
        // 이메일 확인이 켜져 있으면 access_token 이 없을 수 있음 → 로그인 시도
        if (token.accessToken == null) signIn(email, password) else store(token)
    }

    suspend fun signOut() = withContext(Dispatchers.IO) {
        val access = Config.accessToken
        if (access != null) {
            runCatching {
                val req = Request.Builder()
                    .url("$authBase/logout")
                    .header("apikey", Config.supabaseAnonKey)
                    .header("Authorization", "Bearer $access")
                    .post(ByteArray(0).toRequestBody(null))
                    .build()
                http.newCall(req).execute().close()
            }
        }
        Config.clearTokens()
        _isAuthenticated.value = false
    }

    private suspend fun refreshSession(refreshToken: String) = withContext(Dispatchers.IO) {
        val body = json.encodeToString(mapOf("refresh_token" to refreshToken)).toRequestBody(jsonMedia)
        val req = Request.Builder()
            .url("$authBase/token?grant_type=refresh_token")
            .header("apikey", Config.supabaseAnonKey)
            .post(body)
            .build()
        store(execute(req))
    }

    private fun execute(req: Request): TokenResponse {
        http.newCall(req).execute().use { resp ->
            val raw = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw IOException("auth ${resp.code}: $raw")
            return json.decodeFromString(TokenResponse.serializer(), raw)
        }
    }

    private fun store(token: TokenResponse) {
        Config.accessToken = token.accessToken
        Config.refreshToken = token.refreshToken
        _isAuthenticated.value = token.accessToken != null
    }
}
