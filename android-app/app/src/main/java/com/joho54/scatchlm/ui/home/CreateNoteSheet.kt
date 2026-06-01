package com.joho54.scatchlm.ui.home

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.joho54.scatchlm.ScatchLMApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private val LANGUAGES = listOf("en", "ko", "ja", "zh", "fr", "es")

/** iOS CreateNoteSheet 대응. 제목/언어 + 교재 PDF 업로드. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun CreateNoteSheet(
    onDismiss: () -> Unit,
    onCreated: (noteId: String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf("") }
    var language by remember { mutableStateOf("en") }
    var pdfUri by remember { mutableStateOf<Uri?>(null) }
    var pdfName by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        pdfUri = uri
        pdfName = uri?.lastPathSegment
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(24.dp)) {
            Text("새 노트", style = MaterialTheme.typography.titleLarge)

            OutlinedTextField(
                value = title, onValueChange = { title = it },
                label = { Text("제목") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
            )

            Text("작성 언어", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 16.dp, bottom = 8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                LANGUAGES.forEach { lang ->
                    FilterChip(selected = language == lang, onClick = { language = lang }, label = { Text(lang) })
                }
            }

            OutlinedButton(onClick = { picker.launch("application/pdf") }, modifier = Modifier.padding(top = 16.dp)) {
                Text(pdfName?.let { "교재: $it" } ?: "교재 PDF 선택 (선택)")
            }

            Button(
                onClick = {
                    busy = true
                    scope.launch {
                        val note = ScatchLMApp.noteRepo.createNote(title.ifBlank { "제목 없음" }, language)
                        pdfUri?.let { uri ->
                            runCatching {
                                val file = copyToCache(context, uri)
                                val res = ScatchLMApp.pdfRepo.uploadPdf(file, note.id)
                                ScatchLMApp.noteRepo.linkTextbook(note.id, res.id, res.fileName, res.totalPages)
                            }
                        }
                        busy = false
                        onCreated(note.id)
                    }
                },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
            ) {
                if (busy) CircularProgressIndicator(modifier = Modifier.padding(end = 8.dp))
                Text("만들기")
            }
        }
    }
}

private suspend fun copyToCache(context: android.content.Context, uri: Uri): File =
    withContext(Dispatchers.IO) {
        val dest = File(context.cacheDir, "upload_${System.currentTimeMillis()}.pdf")
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input)
            dest.outputStream().use { input.copyTo(it) }
        }
        dest
    }
