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
  overflow: hidden;
  touch-action: none;
  position: relative;
}
canvas {
  position: absolute;
  left: 0; top: 0;
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

/* ── 줌/팬 상태 ── */
let zoomLevel = 1;
const MIN_ZOOM = 1;
const MAX_ZOOM = 4;
let panX = 0, panY = 0;
// 캔버스의 CSS 크기 (논리 픽셀)
let cssW = 0, cssH = 0;
// 컨테이너 크기
let containerW = 0, containerH = 0;

function clampPan() {
  // 줌 상태에서 캔버스가 컨테이너보다 클 때만 팬 허용
  const scaledW = cssW * zoomLevel;
  const scaledH = cssH * zoomLevel;
  const maxPanX = Math.max(0, (scaledW - containerW) / 2);
  const maxPanY = Math.max(0, (scaledH - containerH) / 2);
  panX = Math.max(-maxPanX, Math.min(maxPanX, panX));
  panY = Math.max(-maxPanY, Math.min(maxPanY, panY));
}

function applyTransform() {
  // 가로 중앙 정렬: 캔버스가 컨테이너보다 좁으면 중앙에 배치
  const offsetX = Math.max(0, (containerW - cssW * zoomLevel) / 2);
  canvas.style.transformOrigin = '0 0';
  canvas.style.transform =
    'translate(' + (offsetX + panX) + 'px,' + panY + 'px) scale(' + zoomLevel + ')';
}

function resetView() {
  zoomLevel = 1;
  panX = 0;
  panY = 0;
  applyTransform();
}

async function renderPage(num) {
  if (rendering || !pdfDoc) return;
  rendering = true;

  resetView();

  const page = await pdfDoc.getPage(num);
  const container = document.getElementById('container');
  containerW = container.clientWidth;
  containerH = container.clientHeight;

  const vp = page.getViewport({ scale: 1 });

  // fit-width: 가로폭 기준으로 채움
  const scale = containerW / vp.width;
  const viewport = page.getViewport({ scale });

  // HiDPI 대응
  const dpr = window.devicePixelRatio || 1;
  canvas.width = viewport.width * dpr;
  canvas.height = viewport.height * dpr;
  cssW = viewport.width;
  cssH = viewport.height;
  canvas.style.width = cssW + 'px';
  canvas.style.height = cssH + 'px';

  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  await page.render({ canvasContext: ctx, viewport }).promise;

  rendering = false;
  currentPage = num;
  applyTransform();
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

/* ── 터치 제스처 ── */
let touches0 = [];       // touchstart 시점의 터치 목록
let lastPinchDist = 0;
let isPinching = false;
let lastTapTime = 0;
let panStartX = 0, panStartY = 0;
let panBaseX = 0, panBaseY = 0;

function dist(t1, t2) {
  const dx = t1.clientX - t2.clientX;
  const dy = t1.clientY - t2.clientY;
  return Math.sqrt(dx * dx + dy * dy);
}

document.addEventListener('touchstart', (e) => {
  touches0 = Array.from(e.touches);

  if (e.touches.length === 2) {
    isPinching = true;
    lastPinchDist = dist(e.touches[0], e.touches[1]);
  } else if (e.touches.length === 1) {
    isPinching = false;
    panStartX = e.touches[0].clientX;
    panStartY = e.touches[0].clientY;
    panBaseX = panX;
    panBaseY = panY;
  }
}, { passive: true });

document.addEventListener('touchmove', (e) => {
  if (e.touches.length === 2 && isPinching) {
    // 핀치 줌 — 두 손가락 중심점 기준 확대
    const newDist = dist(e.touches[0], e.touches[1]);
    const ratio = newDist / lastPinchDist;
    const prevZoom = zoomLevel;
    const newZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, zoomLevel * ratio));

    // 핀치 중심점 (컨테이너 좌표)
    const fx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
    const fy = (e.touches[0].clientY + e.touches[1].clientY) / 2;

    // 중심점 기준 pan 보정: 줌 전후로 focal point가 같은 위치를 가리키도록
    const offsetX = Math.max(0, (containerW - cssW * prevZoom) / 2);
    panX = fx - (fx - offsetX - panX) * (newZoom / prevZoom) - Math.max(0, (containerW - cssW * newZoom) / 2);
    panY = fy - (fy - panY) * (newZoom / prevZoom);

    zoomLevel = newZoom;
    lastPinchDist = newDist;
    clampPan();
    applyTransform();
  } else if (e.touches.length === 1 && !isPinching) {
    // 1-finger 팬 (줌 상태이거나 세로 넘침이 있을 때)
    const dx = e.touches[0].clientX - panStartX;
    const dy = e.touches[0].clientY - panStartY;
    panX = panBaseX + dx;
    panY = panBaseY + dy;
    clampPan();
    applyTransform();
  }
}, { passive: true });

document.addEventListener('touchend', (e) => {
  if (isPinching) {
    isPinching = false;
    return;
  }

  // 더블탭 → 줌 리셋
  const now = Date.now();
  if (e.changedTouches.length === 1 && touches0.length === 1) {
    if (now - lastTapTime < 300) {
      resetView();
      lastTapTime = 0;
      return;
    }
    lastTapTime = now;
  }

  // 1x 줌 + 수평 스와이프 → 페이지 이동
  if (zoomLevel <= 1.05 && touches0.length === 1) {
    const dx = e.changedTouches[0].clientX - touches0[0].clientX;
    const dy = e.changedTouches[0].clientY - touches0[0].clientY;
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) {
      if (dx < 0 && currentPage < totalPages) {
        renderPage(currentPage + 1);
      } else if (dx > 0 && currentPage > 1) {
        renderPage(currentPage - 1);
      }
    }
  }
});

// 화면 회전 / 리사이즈 대응
window.addEventListener('resize', () => {
  if (pdfDoc) renderPage(currentPage);
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
