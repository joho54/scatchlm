import React, { useCallback, useRef, useState } from "react";
import { StyleSheet, View, Text, TouchableOpacity } from "react-native";
import { WebView } from "react-native-webview";
import type { WebViewMessageEvent } from "react-native-webview";
import { supabase } from "../services/supabase";

interface PdfViewerProps {
  textbookId: string;
  totalPages: number;
  onPageChanged: (page: number) => void;
  onClose: () => void;
}

const API_BASE = "http://192.168.0.27:8000";

/**
 * PDF.js 기반 단일 페이지 렌더링 + 좌우 스와이프 HTML
 * - CDN에서 PDF.js 로드
 * - 한 번에 한 페이지만 canvas에 렌더링
 * - 터치 스와이프로 이전/다음 페이지 이동
 * - postMessage로 RN에 페이지 변경 알림
 */
function buildPdfHtml(pdfUrl: string, totalPages: number): string {
  return `
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js"></script>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: 100%; height: 100%; overflow: hidden; background: #f5f5f5; }
#container {
  width: 100%; height: 100%;
  display: flex; align-items: center; justify-content: center;
  touch-action: none;
}
canvas {
  max-width: 100%; max-height: 100%;
  background: #fff;
  box-shadow: 0 1px 4px rgba(0,0,0,0.15);
}
#loading {
  position: absolute; top: 50%; left: 50%;
  transform: translate(-50%, -50%);
  color: #999; font-family: sans-serif; font-size: 14px;
}
</style>
</head>
<body>
<div id="container">
  <canvas id="pdf-canvas"></canvas>
  <div id="loading">PDF 로딩 중...</div>
</div>
<script>
pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';

let pdfDoc = null;
let currentPage = 1;
const totalPages = ${totalPages};
let rendering = false;

const canvas = document.getElementById('pdf-canvas');
const ctx = canvas.getContext('2d');
const loadingEl = document.getElementById('loading');

async function renderPage(num) {
  if (rendering || !pdfDoc) return;
  rendering = true;
  const page = await pdfDoc.getPage(num);
  const container = document.getElementById('container');
  const cw = container.clientWidth;
  const ch = container.clientHeight;
  const vp = page.getViewport({ scale: 1 });
  const scale = Math.min(cw / vp.width, ch / vp.height) * 0.95;
  const viewport = page.getViewport({ scale });
  canvas.width = viewport.width;
  canvas.height = viewport.height;
  await page.render({ canvasContext: ctx, viewport }).promise;
  rendering = false;
  currentPage = num;
  window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'page', page: num }));
}

async function loadPdf() {
  try {
    const pdf = await pdfjsLib.getDocument('${pdfUrl}').promise;
    pdfDoc = pdf;
    loadingEl.style.display = 'none';
    await renderPage(1);
  } catch(e) {
    loadingEl.textContent = 'PDF 로드 실패: ' + e.message;
  }
}

// 스와이프 감지
let touchStartX = 0;
let touchStartY = 0;
document.addEventListener('touchstart', (e) => {
  touchStartX = e.touches[0].clientX;
  touchStartY = e.touches[0].clientY;
}, { passive: true });

document.addEventListener('touchend', (e) => {
  const dx = e.changedTouches[0].clientX - touchStartX;
  const dy = e.changedTouches[0].clientY - touchStartY;
  if (Math.abs(dx) < 50 || Math.abs(dy) > Math.abs(dx)) return; // 최소 50px, 수평 우세
  if (dx < 0 && currentPage < totalPages) {
    renderPage(currentPage + 1);
  } else if (dx > 0 && currentPage > 1) {
    renderPage(currentPage - 1);
  }
});

// RN에서 goToPage 호출
window.goToPage = function(num) {
  if (num >= 1 && num <= totalPages) renderPage(num);
};

loadPdf();
</script>
</body>
</html>`;
}

export default function PdfViewer({
  textbookId,
  totalPages,
  onPageChanged,
  onClose,
}: PdfViewerProps) {
  const [currentPage, setCurrentPage] = useState(1);
  const [token, setToken] = useState<string | null>(null);
  const webViewRef = useRef<WebView>(null);

  React.useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getSession();
      setToken(data.session?.access_token ?? null);
    })();
  }, []);

  const goToPage = useCallback(
    (page: number) => {
      const clamped = Math.max(1, Math.min(page, totalPages));
      webViewRef.current?.injectJavaScript(`goToPage(${clamped}); true;`);
    },
    [totalPages]
  );

  const onMessage = useCallback(
    (event: WebViewMessageEvent) => {
      try {
        const data = JSON.parse(event.nativeEvent.data);
        if (data.type === "page") {
          setCurrentPage(data.page);
          onPageChanged(data.page);
        }
      } catch {}
    },
    [onPageChanged]
  );

  if (!token) {
    return (
      <View style={styles.container}>
        <Text style={styles.loadingText}>로딩 중...</Text>
      </View>
    );
  }

  const pdfUrl = `${API_BASE}/api/pdf/${textbookId}/file?token=${token}`;
  const html = buildPdfHtml(pdfUrl, totalPages);

  return (
    <View style={styles.container}>
      {/* 상단 네비게이션 바 */}
      <View style={styles.topBar}>
        <TouchableOpacity onPress={() => goToPage(currentPage - 1)} style={styles.navBtn}>
          <Text style={styles.navBtnText}>{"‹"}</Text>
        </TouchableOpacity>
        <Text style={styles.pageInfo}>
          {currentPage} / {totalPages}
        </Text>
        <TouchableOpacity onPress={() => goToPage(currentPage + 1)} style={styles.navBtn}>
          <Text style={styles.navBtnText}>{"›"}</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={onClose} style={styles.closeBtn}>
          <Text style={styles.closeBtnText}>X</Text>
        </TouchableOpacity>
      </View>

      {/* PDF 렌더링 WebView */}
      <WebView
        ref={webViewRef}
        source={{ html, baseUrl: API_BASE }}
        style={styles.webview}
        originWhitelist={["*"]}
        onMessage={onMessage}
        javaScriptEnabled
        scrollEnabled={false}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#f5f5f5" },
  topBar: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 6,
    paddingHorizontal: 8,
    backgroundColor: "#fff",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#ddd",
    gap: 8,
  },
  navBtn: { paddingHorizontal: 12, paddingVertical: 4 },
  navBtnText: { fontSize: 22, color: "#007AFF", fontWeight: "600" },
  pageInfo: { fontSize: 13, color: "#333", minWidth: 60, textAlign: "center" },
  closeBtn: { position: "absolute", right: 8 },
  closeBtnText: { fontSize: 14, color: "#999", padding: 4 },
  webview: { flex: 1 },
  loadingText: { textAlign: "center", marginTop: 40, color: "#999" },
});
