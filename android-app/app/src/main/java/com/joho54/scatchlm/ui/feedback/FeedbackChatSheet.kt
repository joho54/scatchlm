package com.joho54.scatchlm.ui.feedback

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.joho54.scatchlm.ScatchLMApp
import com.joho54.scatchlm.data.api.dto.ChatMessageDto
import com.joho54.scatchlm.data.api.dto.ChatRequestDto
import com.joho54.scatchlm.data.db.ChatMessageEntity
import dev.jeziellago.compose.markdowntext.MarkdownText
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * iOS FeedbackChatSheet 대응. 피드백 후속 채팅(RAG), 마크다운, 박제.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedbackChatSheet(
    feedbackLocalId: String,
    serverFeedbackId: String?,
    noteId: String,
    textbookId: String?,
    currentPage: Int?,
    onDismiss: () -> Unit,
    onPin: (content: String, serverId: String?) -> Unit,
) {
    val repo = ScatchLMApp.feedbackRepo
    val scope = rememberCoroutineScope()
    val messages = remember { mutableListOf<ChatMessageEntity>().toMutableStateList() }
    var input by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }

    androidx.compose.runtime.LaunchedEffect(feedbackLocalId) {
        messages.clear()
        messages.addAll(repo.chatMessages(feedbackLocalId))
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.85f).padding(16.dp)) {
            Text("피드백 대화", style = MaterialTheme.typography.titleLarge)

            LazyColumn(
                Modifier.fillMaxWidth().weight(1f).padding(vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(messages, key = { it.id }) { msg ->
                    ChatBubble(msg, onPin = { onPin(msg.content, msg.serverMessageId) })
                }
            }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    placeholder = { Text("질문을 입력하세요") },
                    modifier = Modifier.weight(1f),
                    enabled = !sending,
                )
                IconButton(
                    enabled = !sending && input.isNotBlank(),
                    onClick = {
                        val text = input.trim()
                        input = ""
                        sending = true
                        scope.launch {
                            val userMsg = ChatMessageEntity(
                                id = UUID.randomUUID().toString(),
                                feedbackId = feedbackLocalId, role = "user",
                                content = text, createdAt = System.currentTimeMillis(),
                            )
                            messages.add(userMsg)
                            repo.saveChatMessage(userMsg)

                            val history = messages.dropLast(1).map { ChatMessageDto(it.role, it.content) }
                            runCatching {
                                repo.chat(
                                    ChatRequestDto(
                                        message = text, history = history,
                                        responseLanguage = com.joho54.scatchlm.Config.responseLanguage,
                                        textbookId = textbookId, currentPage = currentPage,
                                        noteId = noteId, parentFeedbackId = serverFeedbackId,
                                    )
                                )
                            }.onSuccess { resp ->
                                val asst = ChatMessageEntity(
                                    id = UUID.randomUUID().toString(),
                                    feedbackId = feedbackLocalId, role = "assistant",
                                    content = resp.content, createdAt = System.currentTimeMillis(),
                                    serverMessageId = resp.feedbackId,
                                )
                                messages.add(asst)
                                repo.saveChatMessage(asst)
                            }.onFailure {
                                val err = ChatMessageEntity(
                                    id = UUID.randomUUID().toString(),
                                    feedbackId = feedbackLocalId, role = "assistant",
                                    content = "⚠️ 오류: ${it.message}", createdAt = System.currentTimeMillis(),
                                )
                                messages.add(err)
                            }
                            sending = false
                        }
                    },
                ) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "전송") }
            }
        }
    }
}

@Composable
private fun ChatBubble(msg: ChatMessageEntity, onPin: () -> Unit) {
    val isUser = msg.role == "user"
    Box(Modifier.fillMaxWidth(), contentAlignment = if (isUser) Alignment.CenterEnd else Alignment.CenterStart) {
        Card(
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (isUser) MaterialTheme.colorScheme.primaryContainer
                else MaterialTheme.colorScheme.surfaceVariant
            ),
            modifier = Modifier.widthIn(max = 520.dp),
        ) {
            Column(Modifier.padding(12.dp)) {
                MarkdownText(markdown = msg.content, style = MaterialTheme.typography.bodyMedium)
                if (!isUser) {
                    IconButton(onClick = onPin, modifier = Modifier.align(Alignment.End)) {
                        Icon(Icons.Filled.PushPin, contentDescription = "박제")
                    }
                }
            }
        }
    }
}
