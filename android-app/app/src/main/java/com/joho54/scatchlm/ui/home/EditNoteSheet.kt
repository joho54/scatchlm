package com.joho54.scatchlm.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.joho54.scatchlm.ScatchLMApp
import com.joho54.scatchlm.data.db.NoteEntity
import kotlinx.coroutines.launch

private val LANGUAGES = listOf("en", "ko", "ja", "zh", "fr", "es")

/** iOS EditNoteSheet 대응. 제목/언어 수정. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun EditNoteSheet(
    note: NoteEntity,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf(note.title) }
    var language by remember { mutableStateOf(note.language) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(24.dp)) {
            Text("노트 편집", style = MaterialTheme.typography.titleLarge)

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

            Button(
                onClick = {
                    scope.launch {
                        ScatchLMApp.noteRepo.saveNote(note.copy(title = title.ifBlank { "제목 없음" }, language = language))
                        onSaved()
                    }
                },
                modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
            ) { Text("저장") }
        }
    }
}
