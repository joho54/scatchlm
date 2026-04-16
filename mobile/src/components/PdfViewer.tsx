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
.page-wrap {
  position: absolute;
  top: 0; left: 0;
  width: 100%; height: 100%;
  overflow: hidden;
  will-change: transform;
}
.page-wrap.animating {
  transition: transform 280ms ease-out;
}
.page-canvas {
  position: absolute;
  left: 0; top: 0;
  background: #fff;
  box-shadow: 0 1px 4px rgba(0,0,0,0.15);
  will-change: transform;
}
#loading {
  position: absolute; top: 50%; left: 50%;
  transform: translate(-50%, -50%);
  color: #999; font-family: sans-serif; font-size: 14px;
  z-index: 10;
}
</style>
</head>
<body>
<div id="container">
  <div id="wrap-0" class="page-wrap"><canvas id="c-0" class="page-canvas"></canvas></div>
  <div id="wrap-1" class="page-wrap"><canvas id="c-1" class="page-canvas"></canvas></div>
  <div id="wrap-2" class="page-wrap"><canvas id="c-2" class="page-canvas"></canvas></div>
  <div id="loading">PDF 로딩 중...</div>
</div>
<script>
pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';

let pdfDoc = null;
let currentPage = 1;
const totalPages = ${totalPages};

const container = document.getElementById('container');
const loadingEl = document.getElementById('loading');

/* ── 3-슬롯 캔버스 버퍼 ── */
const slots = [0, 1, 2].map(i => {
  const wrap = document.getElementById('wrap-' + i);
  const canvas = document.getElementById('c-' + i);
  return { wrap, canvas, ctx: canvas.getContext('2d'), page: 0, cssW: 0, cssH: 0 };
});
let currIdx = 1, prevIdx = 0, nextIdx = 2;

/* ── 컨테이너 / 줌 / 팬 상태 ── */
let containerW = 0, containerH = 0;
let zoomLevel = 1, minZoom = 1;
const MAX_ZOOM = 4;
let panX = 0, panY = 0;
let slideOffset = 0;
let isAnimating = false;

function updateContainerSize() {
  containerW = container.clientWidth;
  containerH = container.clientHeight;
}

/* ── 렌더링 ── */
async function renderToSlot(idx, pageNum) {
  const s = slots[idx];
  if (!pdfDoc || pageNum < 1 || pageNum > totalPages) {
    s.page = 0; s.canvas.width = 0; s.cssW = 0; s.cssH = 0;
    return;
  }
  const page = await pdfDoc.getPage(pageNum);
  const vp = page.getViewport({ scale: 1 });
  const scale = containerW / vp.width;
  const viewport = page.getViewport({ scale });
  const dpr = window.devicePixelRatio || 1;
  s.canvas.width = viewport.width * dpr;
  s.canvas.height = viewport.height * dpr;
  s.cssW = viewport.width;
  s.cssH = viewport.height;
  s.canvas.style.width = s.cssW + 'px';
  s.canvas.style.height = s.cssH + 'px';
  s.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  await page.render({ canvasContext: s.ctx, viewport }).promise;
  s.page = pageNum;
}

/* ── Transform 헬퍼 ── */
function centerCanvas(idx) {
  const s = slots[idx];
  if (!s.cssW) return;
  // 프리렌더된 인접 페이지도 minZoom 기준으로 배치 (슬라이드 → 전환 시 깜빡임 방지)
  const zm = (s.cssH > 0) ? Math.min(1, containerH / s.cssH) : 1;
  const ox = Math.max(0, (containerW - s.cssW * zm) / 2);
  const oy = Math.max(0, (containerH - s.cssH * zm) / 2);
  s.canvas.style.transformOrigin = '0 0';
  s.canvas.style.transform = 'translate(' + ox + 'px,' + oy + 'px) scale(' + zm + ')';
}

function applyTransform() {
  const s = slots[currIdx];
  if (!s.cssW) return;
  const ox = Math.max(0, (containerW - s.cssW * zoomLevel) / 2);
  const oy = Math.max(0, (containerH - s.cssH * zoomLevel) / 2);
  s.canvas.style.transformOrigin = '0 0';
  s.canvas.style.transform =
    'translate(' + (ox + panX) + 'px,' + (oy + panY) + 'px) scale(' + zoomLevel + ')';
}

function clampPan() {
  const s = slots[currIdx];
  const sw = s.cssW * zoomLevel, sh = s.cssH * zoomLevel;
  const mX = Math.max(0, (sw - containerW) / 2);
  const mY = Math.max(0, (sh - containerH) / 2);
  panX = Math.max(-mX, Math.min(mX, panX));
  panY = Math.max(-mY, Math.min(mY, panY));
}

function resetZoom() { zoomLevel = minZoom; panX = 0; panY = 0; }

function positionSlots() {
  slots[prevIdx].wrap.style.transform = 'translateX(' + (-containerW + slideOffset) + 'px)';
  slots[currIdx].wrap.style.transform = 'translateX(' + slideOffset + 'px)';
  slots[nextIdx].wrap.style.transform = 'translateX(' + (containerW + slideOffset) + 'px)';
}

function updateMinZoom() {
  const s = slots[currIdx];
  minZoom = (s.cssH > 0) ? Math.min(1, containerH / s.cssH) : 1;
}

/* ── 인접 페이지 프리렌더 ── */
let prerenderGen = 0;
async function prerenderAdjacent() {
  const gen = ++prerenderGen;
  const pg = currentPage;
  if (pg > 1 && slots[prevIdx].page !== pg - 1) {
    await renderToSlot(prevIdx, pg - 1);
    if (gen !== prerenderGen) return;
    centerCanvas(prevIdx);
  }
  if (pg < totalPages && slots[nextIdx].page !== pg + 1) {
    await renderToSlot(nextIdx, pg + 1);
    if (gen !== prerenderGen) return;
    centerCanvas(nextIdx);
  }
}

/* ── 슬라이드 애니메이션 ── */
function commitSlide(dir) {
  return new Promise(function(resolve) {
    isAnimating = true;
    var targetOffset = -dir * containerW;
    slots.forEach(function(s) { s.wrap.classList.add('animating'); });
    slideOffset = targetOffset;
    positionSlots();

    var done = false;
    function onEnd() {
      if (done) return;
      done = true;
      clearTimeout(fb);
      slots.forEach(function(s) { s.wrap.classList.remove('animating'); });

      if (dir === 1) {
        var op = prevIdx; prevIdx = currIdx; currIdx = nextIdx; nextIdx = op;
      } else {
        var on = nextIdx; nextIdx = currIdx; currIdx = prevIdx; prevIdx = on;
      }
      currentPage += dir;
      slideOffset = 0;
      updateMinZoom();
      resetZoom();
      positionSlots();
      applyTransform();
      window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'page', page: currentPage }));
      isAnimating = false;
      resolve();
      prerenderAdjacent();
    }
    slots[currIdx].wrap.addEventListener('transitionend', onEnd, { once: true });
    var fb = setTimeout(onEnd, 350);
  });
}

function snapBack() {
  return new Promise(function(resolve) {
    if (slideOffset === 0) { resolve(); return; }
    isAnimating = true;
    slots.forEach(function(s) { s.wrap.classList.add('animating'); });
    slideOffset = 0;
    positionSlots();

    var done = false;
    function onEnd() {
      if (done) return;
      done = true;
      clearTimeout(fb);
      slots.forEach(function(s) { s.wrap.classList.remove('animating'); });
      isAnimating = false;
      resolve();
    }
    slots[currIdx].wrap.addEventListener('transitionend', onEnd, { once: true });
    var fb = setTimeout(onEnd, 350);
  });
}

/* ── goToPage (RN 브릿지 + 내부) ── */
async function goToPage(num) {
  if (!pdfDoc || num < 1 || num > totalPages || num === currentPage || isAnimating) return;

  if (Math.abs(num - currentPage) === 1) {
    var dir = num > currentPage ? 1 : -1;
    var tgt = dir === 1 ? nextIdx : prevIdx;
    if (slots[tgt].page !== num) {
      await renderToSlot(tgt, num);
      centerCanvas(tgt);
      positionSlots();
    }
    await commitSlide(dir);
    return;
  }

  // 비인접 페이지: 즉시 전환
  resetZoom();
  slideOffset = 0;
  await renderToSlot(currIdx, num);
  currentPage = num;
  updateMinZoom();
  positionSlots();
  applyTransform();
  window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'page', page: currentPage }));
  prerenderAdjacent();
}
window.goToPage = goToPage;

/* ── 초기 로드 ── */
async function loadPdf() {
  try {
    var pdf = await pdfjsLib.getDocument('${pdfUrl}').promise;
    pdfDoc = pdf;
    loadingEl.style.display = 'none';
    updateContainerSize();
    await renderToSlot(currIdx, 1);
    updateMinZoom();
    positionSlots();
    applyTransform();
    window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'page', page: 1 }));
    prerenderAdjacent();
  } catch(e) {
    loadingEl.textContent = 'PDF 로드 실패: ' + e.message;
  }
}

/* ── 터치 제스처 ── */
var touches0 = [];
var lastPinchDist = 0;
var lastTapTime = 0;
var panStartX = 0, panStartY = 0;
var panBaseX = 0, panBaseY = 0;
var gestureMode = 'none'; // none | pinch | pan | slide

function tDist(a, b) {
  var dx = a.clientX - b.clientX, dy = a.clientY - b.clientY;
  return Math.sqrt(dx * dx + dy * dy);
}

document.addEventListener('touchstart', function(e) {
  if (isAnimating) return;
  touches0 = Array.from(e.touches);
  gestureMode = 'none';

  if (e.touches.length === 2) {
    gestureMode = 'pinch';
    lastPinchDist = tDist(e.touches[0], e.touches[1]);
  } else if (e.touches.length === 1) {
    panStartX = e.touches[0].clientX;
    panStartY = e.touches[0].clientY;
    panBaseX = panX;
    panBaseY = panY;
  }
}, { passive: true });

document.addEventListener('touchmove', function(e) {
  if (isAnimating) return;

  /* 핀치 줌 */
  if (e.touches.length === 2 && gestureMode === 'pinch') {
    var nd = tDist(e.touches[0], e.touches[1]);
    var ratio = nd / lastPinchDist;
    var prev = zoomLevel;
    var nz = Math.max(minZoom, Math.min(MAX_ZOOM, zoomLevel * ratio));
    var fx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
    var fy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
    var s = slots[currIdx];
    var oxO = Math.max(0, (containerW - s.cssW * prev) / 2);
    var oyO = Math.max(0, (containerH - s.cssH * prev) / 2);
    var oxN = Math.max(0, (containerW - s.cssW * nz) / 2);
    var oyN = Math.max(0, (containerH - s.cssH * nz) / 2);
    panX = fx - (fx - oxO - panX) * (nz / prev) - oxN;
    panY = fy - (fy - oyO - panY) * (nz / prev) - oyN;
    zoomLevel = nz;
    lastPinchDist = nd;
    clampPan();
    applyTransform();
    return;
  }

  /* 1-finger */
  if (e.touches.length === 1 && gestureMode !== 'pinch') {
    var dx = e.touches[0].clientX - panStartX;
    var dy = e.touches[0].clientY - panStartY;

    if (gestureMode === 'none') {
      if (zoomLevel > 1.05) {
        gestureMode = 'pan';
      } else {
        if (Math.abs(dx) > 8) gestureMode = 'slide';
        else if (Math.abs(dy) > 8) gestureMode = 'pan';
        else return;
      }
    }

    if (gestureMode === 'slide') {
      var off = dx;
      if ((currentPage <= 1 && dx > 0) || (currentPage >= totalPages && dx < 0)) {
        off = dx * 0.3;
      }
      slideOffset = off;
      positionSlots();
    } else if (gestureMode === 'pan') {
      panX = panBaseX + dx;
      panY = panBaseY + dy;
      clampPan();
      applyTransform();
    }
  }
}, { passive: true });

document.addEventListener('touchend', function(e) {
  if (isAnimating) return;

  if (gestureMode === 'pinch') { gestureMode = 'none'; return; }

  if (gestureMode === 'slide') {
    var dx = slideOffset;
    var th = containerW * 0.2;
    if (dx < -th && currentPage < totalPages) commitSlide(1);
    else if (dx > th && currentPage > 1) commitSlide(-1);
    else snapBack();
    gestureMode = 'none';
    return;
  }

  /* 더블탭 */
  var now = Date.now();
  if (e.changedTouches.length === 1 && touches0.length === 1 && gestureMode !== 'pan') {
    if (now - lastTapTime < 300) {
      var tx = e.changedTouches[0].clientX;
      var ty = e.changedTouches[0].clientY;
      if (zoomLevel > minZoom + 0.05) {
        resetZoom();
      } else {
        var nz = 2;
        var s = slots[currIdx];
        var oxO = Math.max(0, (containerW - s.cssW * zoomLevel) / 2);
        var oyO = Math.max(0, (containerH - s.cssH * zoomLevel) / 2);
        var oxN = Math.max(0, (containerW - s.cssW * nz) / 2);
        var oyN = Math.max(0, (containerH - s.cssH * nz) / 2);
        panX = tx - (tx - oxO - panX) * (nz / zoomLevel) - oxN;
        panY = ty - (ty - oyO - panY) * (nz / zoomLevel) - oyN;
        zoomLevel = nz;
      }
      clampPan();
      applyTransform();
      lastTapTime = 0;
      gestureMode = 'none';
      return;
    }
    lastTapTime = now;
  }
  gestureMode = 'none';
});

/* ── 리사이즈 ── */
window.addEventListener('resize', function() {
  if (!pdfDoc) return;
  updateContainerSize();
  resetZoom();
  slideOffset = 0;
  renderToSlot(currIdx, currentPage).then(function() {
    updateMinZoom();
    positionSlots();
    applyTransform();
    prerenderAdjacent();
  });
});

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
