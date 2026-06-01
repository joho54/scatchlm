package com.joho54.scatchlm

import android.content.Context
import android.content.SharedPreferences

/**
 * iOS `Config.swift` 대응. 빌드 설정값(API host, Supabase) + 사용자 환경설정(UserDefaults → SharedPreferences).
 */
object Config {
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("scatchlm_prefs", Context.MODE_PRIVATE)
    }

    // MARK: - Backend API
    /**
     * 기본값은 BuildConfig(debug=10.0.2.2:18000, release=scatchlm.duckdns.org).
     * 실기기 디버깅 시 같은 Wi-Fi 의 Mac LAN IP 로 덮어쓸 수 있음.
     */
    var apiBaseUrlOverride: String?
        get() = prefs.getString("apiBaseUrlOverride", null)?.takeIf { it.isNotBlank() }
        set(value) = prefs.edit().putString("apiBaseUrlOverride", value).apply()

    val apiBaseUrl: String
        get() = apiBaseUrlOverride ?: BuildConfig.API_BASE_URL

    // MARK: - Supabase
    val supabaseUrl: String get() = BuildConfig.SUPABASE_URL
    val supabaseAnonKey: String get() = BuildConfig.SUPABASE_ANON_KEY

    // MARK: - App
    const val BUNDLE_ID = "com.joho54.scatchlm"

    // MARK: - User Preferences
    var responseLanguage: String
        get() = prefs.getString("responseLanguage", "Korean") ?: "Korean"
        set(value) = prefs.edit().putString("responseLanguage", value).apply()

    // MARK: - Auth tokens (Supabase GoTrue)
    var accessToken: String?
        get() = prefs.getString("accessToken", null)
        set(value) = prefs.edit().putString("accessToken", value).apply()

    var refreshToken: String?
        get() = prefs.getString("refreshToken", null)
        set(value) = prefs.edit().putString("refreshToken", value).apply()

    fun clearTokens() {
        prefs.edit().remove("accessToken").remove("refreshToken").apply()
    }
}
