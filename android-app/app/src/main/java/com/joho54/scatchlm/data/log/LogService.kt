package com.joho54.scatchlm.data.log

import android.util.Log
import com.joho54.scatchlm.data.api.ApiClient
import com.joho54.scatchlm.data.api.dto.LogBatchDto
import com.joho54.scatchlm.data.api.dto.LogEntryDto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * iOS `LogService.swift` 대응. 메모리 큐(≤50) + 2초 주기 flush → POST /dev/log/batch.
 * api 는 Application 에서 attachApi 로 주입(생성 순서 때문).
 */
class LogService(scope: CoroutineScope) {
    private val queue = ArrayDeque<LogEntryDto>()
    private val lock = Any()
    private var api: ApiClient? = null

    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)

    init {
        scope.launch {
            while (true) {
                delay(2000)
                flush()
            }
        }
    }

    fun attachApi(client: ApiClient) {
        api = client
    }

    fun log(level: String, tag: String, message: String, data: Map<String, Any?>? = null) {
        val full = if (data.isNullOrEmpty()) message
        else "$message ${data.entries.joinToString(prefix = "{", postfix = "}") { "${it.key}=${it.value}" }}"
        when (level) {
            "error" -> Log.e("FE/$tag", full)
            "warn" -> Log.w("FE/$tag", full)
            else -> Log.d("FE/$tag", full)
        }
        synchronized(lock) {
            queue.addLast(LogEntryDto(level = level, tag = tag, message = full, timestamp = iso.format(Date())))
            while (queue.size > 50) queue.removeFirst()
        }
    }

    private suspend fun flush() {
        val batch: List<LogEntryDto>
        synchronized(lock) {
            if (queue.isEmpty()) return
            batch = queue.toList()
            queue.clear()
        }
        api?.postLogBatch(LogBatchDto(batch))
    }
}

/* iOS appLog / appLogError 전역 헬퍼 대응 */
fun appLog(tag: String, message: String, data: Map<String, Any?>? = null) {
    runCatching { com.joho54.scatchlm.ScatchLMApp.log.log("info", tag, message, data) }
}

fun appLogError(tag: String, message: String, data: Map<String, Any?>? = null) {
    runCatching { com.joho54.scatchlm.ScatchLMApp.log.log("error", tag, message, data) }
}
