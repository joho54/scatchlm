package com.joho54.scatchlm.ui.pdf

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.joho54.scatchlm.Config
import com.joho54.scatchlm.ScatchLMApp
import com.joho54.scatchlm.data.api.dto.ChapterDto
import com.joho54.scatchlm.data.api.dto.ChatRequestDto
import com.joho54.scatchlm.data.api.dto.PageGuideDto
import dev.jeziellago.compose.markdowntext.MarkdownText
import kotlinx.coroutines.launch
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PdfViewerScreen(
    textbookId: String,
    noteId: String?,
    onBack: () -> Unit,
) {
    val pdfRepo = ScatchLMApp.pdfRepo
    val scope = rememberCoroutineScope()

    var currentPage by remember { mutableIntStateOf(1) }
    var tab by remember { mutableIntStateOf(0) }

    val file by produceState<File?>(initialValue = null, textbookId) {
        value = runCatching { pdfRepo.cachedPdf(textbookId) }.getOrNull()
    }
    val chapters by produceState<List<ChapterDto>>(initialValue = emptyList(), textbookId) {
        value = runCatching { pdfRepo.chapters(textbookId) }.getOrDefault(emptyList())
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("교재") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "뒤로")
                    }
                },
            )
        },
    ) { padding ->
        Row(Modifier.fillMaxSize().padding(padding)) {
            // PDF
            Box(Modifier.weight(0.6f).fillMaxHeight()) {
                file?.let {
                    PdfView(file = it, initialPage = currentPage, onPageChanged = { p -> currentPage = p })
                } ?: Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
            }

            Divider(Modifier.fillMaxHeight().width(1.dp))

            // 사이드 패널
            Column(Modifier.weight(0.4f).fillMaxHeight()) {
                TabRow(selectedTabIndex = tab) {
                    Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("목차") })
                    Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("가이드") })
                }
                when (tab) {
                    0 -> ChapterList(chapters, onSelect = { currentPage = it.pageStart })
                    else -> GuidePanel(textbookId, currentPage, noteId)
                }
            }
        }
    }
}

@Composable
private fun ChapterList(chapters: List<ChapterDto>, onSelect: (ChapterDto) -> Unit) {
    LazyColumn(Modifier.fillMaxSize()) {
        items(chapters, key = { it.id }) { ch ->
            Text(
                "${"  ".repeat((ch.level - 1).coerceAtLeast(0))}${ch.title}  (p.${ch.pageStart})",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.fillMaxWidth().clickable { onSelect(ch) }.padding(12.dp),
            )
            Divider()
        }
    }
}

@Composable
private fun GuidePanel(textbookId: String, page: Int, noteId: String?) {
    val pdfRepo = ScatchLMApp.pdfRepo
    val feedbackRepo = ScatchLMApp.feedbackRepo
    val scope = rememberCoroutineScope()

    var guide by remember(page) { mutableStateOf<PageGuideDto?>(null) }
    var loading by remember(page) { mutableStateOf(true) }
    var chatInput by remember { mutableStateOf("") }
    var chatAnswer by remember { mutableStateOf<String?>(null) }
    var chatBusy by remember { mutableStateOf(false) }

    LaunchedEffect(textbookId, page) {
        loading = true
        guide = runCatching { pdfRepo.pageGuide(textbookId, page, Config.responseLanguage) }.getOrNull()
        loading = false
    }

    Column(Modifier.fillMaxSize().padding(12.dp).verticalScroll(rememberScrollState())) {
        if (loading) {
            CircularProgressIndicator()
        } else guide?.let { g ->
            Text(g.topic.ifBlank { "p.$page 가이드" }, style = MaterialTheme.typography.titleMedium)
            MarkdownText(markdown = g.content, modifier = Modifier.padding(top = 8.dp))
            if (g.keyPoints.isNotEmpty()) {
                Text("핵심", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 12.dp))
                g.keyPoints.forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) }
            }
        } ?: Text("가이드를 불러오지 못했습니다.")

        Divider(Modifier.padding(vertical = 16.dp))

        Text("질문하기", style = MaterialTheme.typography.titleSmall)
        chatAnswer?.let { MarkdownText(markdown = it, modifier = Modifier.padding(vertical = 8.dp)) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = chatInput, onValueChange = { chatInput = it },
                placeholder = { Text("이 페이지에 대해 질문") },
                modifier = Modifier.weight(1f), enabled = !chatBusy,
            )
            IconButton(enabled = !chatBusy && chatInput.isNotBlank(), onClick = {
                val q = chatInput.trim(); chatInput = ""; chatBusy = true
                scope.launch {
                    chatAnswer = runCatching {
                        feedbackRepo.chat(
                            ChatRequestDto(
                                message = q, responseLanguage = Config.responseLanguage,
                                textbookId = textbookId, currentPage = page, noteId = noteId,
                            )
                        ).content
                    }.getOrElse { "⚠️ 오류: ${it.message}" }
                    chatBusy = false
                }
            }) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "전송") }
        }
    }
}
