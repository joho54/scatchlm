package com.joho54.scatchlm.ui.note

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.joho54.scatchlm.Config
import com.joho54.scatchlm.ScatchLMApp
import com.joho54.scatchlm.data.db.FeedbackEntity
import com.joho54.scatchlm.data.db.NoteEntity
import com.joho54.scatchlm.ui.draw.DrawingCodec
import com.joho54.scatchlm.ui.draw.DrawingController
import com.joho54.scatchlm.ui.draw.InkCanvas
import com.joho54.scatchlm.ui.draw.InkRender
import com.joho54.scatchlm.ui.feedback.FeedbackChatSheet
import dev.jeziellago.compose.markdowntext.MarkdownText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

private const val CANVAS_HEIGHT_DP = 3000

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteScreen(
    noteId: String,
    onBack: () -> Unit,
    onOpenPdf: (textbookId: String) -> Unit,
) {
    val noteRepo = ScatchLMApp.noteRepo
    val feedbackRepo = ScatchLMApp.feedbackRepo
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    val controller = remember { DrawingController() }
    var note by remember { mutableStateOf<NoteEntity?>(null) }
    var currentPageId by remember { mutableStateOf<String?>(null) }
    var currentPageIndex by remember { mutableIntStateOf(0) }
    var pageCount by remember { mutableIntStateOf(1) }
    val feedbacks = remember { mutableListOf<FeedbackEntity>().toMutableStateList() }
    var requesting by remember { mutableStateOf(false) }
    var chatFor by remember { mutableStateOf<FeedbackEntity?>(null) }

    // 노트 + 현재 페이지 로드
    LaunchedEffect(noteId) {
        val n = noteRepo.getNote(noteId) ?: return@LaunchedEffect
        note = n
        val pages = noteRepo.pages(noteId)
        pageCount = pages.size
        currentPageIndex = n.currentPageIndex.coerceIn(0, pages.lastIndex)
        loadPage(noteRepo, feedbackRepo, controller, feedbacks, n, currentPageIndex) { id ->
            currentPageId = id
        }
    }

    // 페이지 드로잉 자동 저장 (화면 떠날 때)
    DisposableEffect(noteId) {
        onDispose {
            val pid = currentPageId ?: return@onDispose
            val data = controller.export()
            ScatchLMApp.appScope.launch {
                noteRepo.savePageDrawing(pid, DrawingCodec.encode(data))
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(note?.title ?: "노트") },
                navigationIcon = {
                    IconButton(onClick = {
                        currentPageId?.let { pid ->
                            scope.launch { noteRepo.savePageDrawing(pid, DrawingCodec.encode(controller.export())) }
                        }
                        onBack()
                    }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "뒤로") }
                },
                actions = {
                    IconButton(onClick = { controller.isEraser = false }) {
                        Icon(Icons.Filled.Edit, contentDescription = "펜", tint = if (!controller.isEraser) MaterialTheme.colorScheme.primary else Color.Gray)
                    }
                    IconButton(onClick = { controller.isEraser = true }) {
                        Icon(Icons.Filled.AutoFixHigh, contentDescription = "지우개", tint = if (controller.isEraser) MaterialTheme.colorScheme.primary else Color.Gray)
                    }
                    IconButton(onClick = { controller.undo() }) { Icon(Icons.AutoMirrored.Filled.Undo, contentDescription = "되돌리기") }
                    IconButton(onClick = { controller.redo() }) { Icon(Icons.AutoMirrored.Filled.Redo, contentDescription = "다시") }
                    note?.textbookId?.let { tid ->
                        IconButton(onClick = { onOpenPdf(tid) }) { Icon(Icons.Filled.MenuBook, contentDescription = "교재") }
                    }
                    IconButton(
                        enabled = !requesting,
                        onClick = {
                            requesting = true
                            scope.launch {
                                requestFeedback(noteRepo, feedbackRepo, controller, feedbacks, note, currentPageId)
                                requesting = false
                            }
                        },
                    ) {
                        if (requesting) CircularProgressIndicator(Modifier.width(20.dp))
                        else Icon(Icons.Filled.Send, contentDescription = "피드백 요청")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            // 페이지 네비게이터 (간단형)
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("페이지 ${currentPageIndex + 1} / $pageCount")
                IconButton(onClick = {
                    scope.launch {
                        currentPageId?.let { noteRepo.savePageDrawing(it, DrawingCodec.encode(controller.export())) }
                        val newIndex = pageCount
                        noteRepo.createPage(noteId, newIndex)
                        pageCount += 1
                        currentPageIndex = newIndex
                        note?.let { loadPage(noteRepo, feedbackRepo, controller, feedbacks, it, newIndex) { id -> currentPageId = id } }
                    }
                }) { Icon(Icons.Filled.Add, contentDescription = "페이지 추가") }
            }

            val scroll = rememberScrollState()
            Box(
                Modifier.fillMaxSize().verticalScroll(scroll)
                    .height(CANVAS_HEIGHT_DP.dp).background(Color.White)
            ) {
                InkCanvas(controller = controller, modifier = Modifier.fillMaxSize())

                // 피드백 카드 오버레이
                feedbacks.forEach { fb ->
                    val xDp = with(density) { fb.bboxX.toFloat().toDp() }
                    val yDp = with(density) { (fb.bboxY + fb.bboxHeight).toFloat().toDp() }
                    FeedbackCard(
                        feedback = fb,
                        modifier = Modifier.offset(x = xDp, y = yDp).width(360.dp),
                        onChat = { chatFor = fb },
                    )
                }
            }
        }
    }

    chatFor?.let { fb ->
        FeedbackChatSheet(
            feedbackLocalId = fb.id,
            serverFeedbackId = fb.serverFeedbackId,
            noteId = noteId,
            textbookId = note?.textbookId,
            currentPage = note?.lastPage,
            onDismiss = { chatFor = null },
            onPin = { _, _ -> chatFor = null },
        )
    }
}

@Composable
private fun FeedbackCard(
    feedback: FeedbackEntity,
    modifier: Modifier = Modifier,
    onChat: () -> Unit,
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
    ) {
        Column(Modifier.padding(12.dp)) {
            MarkdownText(markdown = feedback.content, style = MaterialTheme.typography.bodyMedium)
            Text(
                "대화하기",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 8.dp).align(Alignment.End)
                    .clickable { onChat() },
            )
        }
    }
}

/** 페이지 로드: 드로잉 + 피드백 복원. */
private suspend fun loadPage(
    noteRepo: com.joho54.scatchlm.data.repo.NoteRepository,
    feedbackRepo: com.joho54.scatchlm.data.repo.FeedbackRepository,
    controller: DrawingController,
    feedbacks: MutableList<FeedbackEntity>,
    note: NoteEntity,
    pageIndex: Int,
    onPageId: (String) -> Unit,
) {
    val page = noteRepo.page(note.id, pageIndex) ?: noteRepo.createPage(note.id, pageIndex)
    onPageId(page.id)
    noteRepo.updateCurrentPageIndex(note.id, pageIndex)
    val data = withContext(Dispatchers.Default) { DrawingCodec.decode(page.drawingData) }
    controller.load(data)
    feedbacks.clear()
    feedbacks.addAll(feedbackRepo.byPage(page.id))
    // frozen 복원: 마지막 피드백 하단으로
    feedbacks.maxByOrNull { it.bboxY + it.bboxHeight }?.let {
        controller.freeze((it.bboxY + it.bboxHeight).toFloat())
    }
}

/** 피드백 요청. iOS NoteView.requestFeedback 대응. */
private suspend fun requestFeedback(
    noteRepo: com.joho54.scatchlm.data.repo.NoteRepository,
    feedbackRepo: com.joho54.scatchlm.data.repo.FeedbackRepository,
    controller: DrawingController,
    feedbacks: MutableList<FeedbackEntity>,
    note: NoteEntity?,
    pageId: String?,
) {
    note ?: return
    pageId ?: return
    val newStrokes = controller.newStrokes()
    val rendered = withContext(Dispatchers.Default) { InkRender.renderToJpeg(newStrokes) } ?: return
    val (jpeg, bounds) = rendered

    val fields = buildMap {
        put("note_id", note.id)
        put("language", note.language)
        put("response_language", Config.responseLanguage)
        note.textbookId?.let { put("textbook_id", it) }
        put("current_page", note.lastPage.toString())
    }

    val resp = runCatching { feedbackRepo.requestFeedback(jpeg, fields) }.getOrNull() ?: return

    val fb = FeedbackEntity(
        id = UUID.randomUUID().toString(),
        noteId = note.id,
        pageId = pageId,
        content = resp.displayText,
        positionX = bounds.minX.toDouble(),
        positionY = (bounds.maxY + 16f).toDouble(),
        bboxX = bounds.minX.toDouble(),
        bboxY = bounds.minY.toDouble(),
        bboxWidth = bounds.width.toDouble(),
        bboxHeight = bounds.height.toDouble(),
        strokeRangeStart = controller.frozenEndIndex,
        strokeRangeEnd = controller.strokeCount,
        createdAt = System.currentTimeMillis(),
        serverFeedbackId = resp.feedbackId,
    )
    feedbackRepo.saveFeedback(fb)
    feedbacks.add(fb)
    controller.freeze(bounds.maxY + 200f) // 카드 높이만큼 여유
}
