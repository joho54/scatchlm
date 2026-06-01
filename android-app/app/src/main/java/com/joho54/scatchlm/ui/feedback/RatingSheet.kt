package com.joho54.scatchlm.ui.feedback

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

private val TAGS = listOf(
    "정확해요", "이해가 잘 돼요", "도움이 됐어요",
    "부정확해요", "너무 길어요", "핵심을 놓쳤어요", "관련 없어요",
)

/**
 * iOS FeedbackRatingSheet 대응. 좋음/아쉬움 + 태그 + 코멘트.
 * @param onSubmit (rating: 1 또는 -1, tags, comment?)
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun RatingSheet(
    onDismiss: () -> Unit,
    onSubmit: (rating: Int, tags: List<String>, comment: String?) -> Unit,
) {
    var rating by remember { mutableStateOf(0) }
    val selectedTags = remember { mutableListOf<String>().toMutableStateList() }
    var comment by remember { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(24.dp)) {
            Text("이 피드백 어땠나요?", style = MaterialTheme.typography.titleLarge)

            Row(
                Modifier.fillMaxWidth().padding(top = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedButton(onClick = { rating = 1 }) {
                    Icon(Icons.Filled.ThumbUp, contentDescription = "좋음")
                    Text("  좋음")
                }
                OutlinedButton(onClick = { rating = -1 }) {
                    Icon(Icons.Filled.ThumbDown, contentDescription = "아쉬움")
                    Text("  아쉬움")
                }
                if (rating != 0) {
                    Text(
                        if (rating == 1) "👍 선택됨" else "👎 선택됨",
                        modifier = Modifier.padding(start = 8.dp, top = 12.dp),
                    )
                }
            }

            Text("이유 (선택)", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp, bottom = 8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TAGS.forEach { tag ->
                    FilterChip(
                        selected = tag in selectedTags,
                        onClick = { if (tag in selectedTags) selectedTags.remove(tag) else selectedTags.add(tag) },
                        label = { Text(tag) },
                    )
                }
            }

            OutlinedTextField(
                value = comment,
                onValueChange = { if (it.length <= 2000) comment = it },
                label = { Text("코멘트 (선택, 최대 2000자)") },
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                minLines = 2,
            )

            Button(
                onClick = {
                    onSubmit(if (rating == 0) 1 else rating, selectedTags.toList(), comment.ifBlank { null })
                    onDismiss()
                },
                enabled = rating != 0,
                modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
            ) { Text("제출") }
        }
    }
}
