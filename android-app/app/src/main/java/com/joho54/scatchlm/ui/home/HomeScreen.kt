package com.joho54.scatchlm.ui.home

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.joho54.scatchlm.ScatchLMApp
import com.joho54.scatchlm.data.db.NoteEntity
import com.joho54.scatchlm.ui.draw.DrawingCodec
import com.joho54.scatchlm.ui.draw.InkRender
import com.joho54.scatchlm.ui.settings.SettingsSheet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onOpenNote: (String) -> Unit,
    onSignedOut: () -> Unit,
) {
    val repo = ScatchLMApp.noteRepo
    val scope = rememberCoroutineScope()
    val notes by repo.observeNotes().collectAsState(initial = emptyList())

    var showCreate by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<NoteEntity?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("ScatchLM") },
                actions = {
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Filled.Settings, contentDescription = "설정")
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreate = true }) {
                Icon(Icons.Filled.Add, contentDescription = "새 노트")
            }
        },
    ) { padding ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 200.dp),
            modifier = Modifier.fillMaxSize().padding(padding).padding(12.dp),
        ) {
            items(notes, key = { it.id }) { note ->
                NoteCard(
                    note = note,
                    onOpen = { onOpenNote(note.id) },
                    onEdit = { editing = note },
                    onDelete = { scope.launch { repo.deleteNote(note.id) } },
                )
            }
        }
    }

    if (showCreate) {
        CreateNoteSheet(onDismiss = { showCreate = false }, onCreated = { id ->
            showCreate = false
            onOpenNote(id)
        })
    }
    editing?.let { note ->
        EditNoteSheet(note = note, onDismiss = { editing = null }, onSaved = { editing = null })
    }
    if (showSettings) {
        SettingsSheet(onDismiss = { showSettings = false }, onSignedOut = onSignedOut)
    }
}

@Composable
private fun NoteCard(
    note: NoteEntity,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }

    val thumb by produceState<Bitmap?>(initialValue = null, note.id, note.updatedAt) {
        value = withContext(Dispatchers.Default) {
            val page0 = ScatchLMApp.noteRepo.page(note.id, 0)
            val data = DrawingCodec.decode(page0?.drawingData)
            InkRender.renderThumbnail(data.strokes, targetPx = 400)
        }
    }

    Card(modifier = Modifier.padding(8.dp).clickable { onOpen() }) {
        Column {
            Box(
                Modifier.fillMaxWidth().aspectRatio(1.4f)
                    .background(Color.White, RoundedCornerShape(4.dp)),
                contentAlignment = Alignment.Center,
            ) {
                thumb?.let {
                    Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Fit)
                } ?: Text("✎", style = MaterialTheme.typography.headlineMedium, color = Color.LightGray)
            }
            Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
                Column {
                    Text(note.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        note.language + (note.textbookName?.let { " · $it" } ?: ""),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                IconButton(onClick = { menu = true }, modifier = Modifier.align(Alignment.TopEnd)) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "메뉴")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("편집") }, onClick = { menu = false; onEdit() })
                    DropdownMenuItem(text = { Text("삭제") }, onClick = { menu = false; onDelete() })
                }
            }
        }
    }
}
