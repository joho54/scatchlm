package com.joho54.scatchlm.ui.pdf

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** 다크모드 색 반전 매트릭스 (iOS colorInvert 대응) */
private val InvertFilter = ColorFilter.colorMatrix(
    ColorMatrix(
        floatArrayOf(
            -1f, 0f, 0f, 0f, 255f,
            0f, -1f, 0f, 0f, 255f,
            0f, 0f, -1f, 0f, 255f,
            0f, 0f, 0f, 1f, 0f,
        )
    )
)

/**
 * PDF 뷰어 Composable. 캐시 파일을 페이지 단위로 렌더한다.
 * @param initialPage 1-indexed (iOS/백엔드 규약과 동일)
 * @param onPageChanged 1-indexed 페이지 변경 콜백
 */
@Composable
fun PdfView(
    file: File,
    initialPage: Int = 1,
    darkInvert: Boolean = isSystemInDarkTheme(),
    onPageChanged: (Int) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val source = remember(file.path) { runCatching { PdfDocumentSource(file) }.getOrNull() }
    DisposableEffect(source) { onDispose { source?.close() } }

    if (source == null) {
        Box(modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
        return
    }

    val pageCount = source.pageCount
    val pagerState = rememberPagerState(
        initialPage = (initialPage - 1).coerceIn(0, (pageCount - 1).coerceAtLeast(0)),
        pageCount = { pageCount }
    )

    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.currentPage }.collect { onPageChanged(it + 1) }
    }

    val density = LocalDensity.current
    HorizontalPager(state = pagerState, modifier = modifier.fillMaxSize()) { pageIndex ->
        var bitmap by remember(pageIndex) { mutableStateOf<Bitmap?>(null) }
        val widthPx = with(density) { 1200.dp.toPx().toInt() }

        LaunchedEffect(pageIndex) {
            bitmap = withContext(Dispatchers.Default) {
                runCatching { source.renderPage(pageIndex, widthPx) }.getOrNull()
            }
        }

        Box(
            Modifier.fillMaxSize().background(if (darkInvert) Color.Black else Color.White),
            contentAlignment = Alignment.Center,
        ) {
            bitmap?.let { bmp ->
                Image(
                    bitmap = bmp.asImageBitmap(),
                    contentDescription = "PDF page ${pageIndex + 1}",
                    contentScale = ContentScale.Fit,
                    colorFilter = if (darkInvert) InvertFilter else null,
                    modifier = Modifier.fillMaxWidth(),
                )
            } ?: CircularProgressIndicator()
        }
    }
}
