package com.joho54.scatchlm

import android.app.Application
import com.joho54.scatchlm.data.api.ApiClient
import com.joho54.scatchlm.data.auth.AuthRepository
import com.joho54.scatchlm.data.db.AppDatabase
import com.joho54.scatchlm.data.log.LogService
import com.joho54.scatchlm.data.repo.FeedbackRepository
import com.joho54.scatchlm.data.repo.NoteRepository
import com.joho54.scatchlm.data.repo.PdfRepository

/**
 * iOS `ScatchLMApp.swift` 대응. 싱글톤 서비스(DB, Auth, Api, Log)를 앱 시작 시 초기화하고
 * 간단한 서비스 로케이터로 노출한다. (앱 규모상 Hilt 없이 수동 DI)
 */
class ScatchLMApp : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this

        Config.init(this)
        database = AppDatabase.build(this)
        log = LogService(scope = appScope)
        auth = AuthRepository()
        api = ApiClient(authProvider = { auth.accessToken }, log = log)
        log.attachApi(api)
        auth.initialize(this, appScope)

        noteRepo = NoteRepository(database)
        feedbackRepo = FeedbackRepository(database, api)
        pdfRepo = PdfRepository(database, api, cacheDir)
    }

    companion object {
        lateinit var instance: ScatchLMApp
            private set

        lateinit var database: AppDatabase
            private set
        lateinit var auth: AuthRepository
            private set
        lateinit var api: ApiClient
            private set
        lateinit var log: LogService
            private set
        lateinit var noteRepo: NoteRepository
            private set
        lateinit var feedbackRepo: FeedbackRepository
            private set
        lateinit var pdfRepo: PdfRepository
            private set

        // 앱 수명 동안 유지되는 코루틴 스코프
        val appScope = kotlinx.coroutines.CoroutineScope(
            kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default
        )
    }
}
