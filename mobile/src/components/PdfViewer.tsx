import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  StyleSheet,
  View,
  Text,
  TouchableOpacity,
  Modal,
  ScrollView,
  ActivityIndicator,
  Platform,
  Image,
} from "react-native";
import Pdf from "react-native-pdf";
import Constants from "expo-constants";
import { supabase } from "../services/supabase";
import api from "../services/api";
import { savePdfDrawing, loadPdfDrawing } from "../services/database";

// PencilKit for PDF annotation
let PencilKitViewComponent: any = null;
if (Platform.OS === "ios") {
  try {
    const mod = require("expo-pencilkit-ui");
    PencilKitViewComponent = mod.PencilKitView ?? mod.default;
  } catch {}
}

const apiHost = Constants.expoConfig?.extra?.apiHost;
if (!apiHost) throw new Error("apiHost not configured in app.config.js extra");
const API_BASE = `http://${apiHost}:8000`;

interface PageGuide {
  page: number;
  topic: string;
  key_points: string[];
  exercises: string[];
  connections: string;
  cached: boolean;
}

interface ChapterItem {
  id: string;
  level: number;
  title: string;
  pageStart: number;
  pageEnd: number;
}

interface ChapterGuide {
  chapter_id: string;
  title: string;
  topic: string;
  key_concepts: string[];
  study_order: string[];
  common_mistakes: string[];
  summary: string;
  cached: boolean;
}

interface PdfViewerProps {
  textbookId: string;
  totalPages: number;
  initialPage?: number;
  onPageChanged: (page: number) => void;
  onClose: () => void;
}

export default function PdfViewer({
  textbookId,
  totalPages,
  initialPage = 1,
  onPageChanged,
  onClose,
}: PdfViewerProps) {
  const [currentPage, setCurrentPage] = useState(initialPage);
  const [token, setToken] = useState<string | null>(null);
  const [guideVisible, setGuideVisible] = useState(false);
  const [guide, setGuide] = useState<PageGuide | null>(null);
  const [guideLoading, setGuideLoading] = useState(false);
  const [tocVisible, setTocVisible] = useState(false);
  const [chapters, setChapters] = useState<ChapterItem[]>([]);
  const [tocLoaded, setTocLoaded] = useState(false);
  const [chapterGuide, setChapterGuide] = useState<ChapterGuide | null>(null);
  const [chapterGuideLoading, setChapterGuideLoading] = useState(false);
  const [chapterGuideVisible, setChapterGuideVisible] = useState(false);
  const [drawingMode, setDrawingMode] = useState(false);
  const [drawingImage, setDrawingImage] = useState<string | null>(null);
  const pencilKitRef = useRef<any>(null);
  const currentPageRef = useRef(initialPage);
  const pdfRef = useRef<any>(null);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getSession();
      setToken(data.session?.access_token ?? null);
    })();
  }, []);


  // 현재 페이지 필기를 저장
  const saveCurrentDrawing = useCallback(async () => {
    if (!pencilKitRef.current) return;
    try {
      const base64 = await pencilKitRef.current.getCanvasDataAsBase64();
      console.log("[pdf-draw] save:", { page: currentPageRef.current, len: base64?.length ?? 0 });
      if (base64) {
        await savePdfDrawing(textbookId, currentPageRef.current, base64);
        setDrawingImage(base64);
      }
    } catch (e: any) {
      console.log("[pdf-draw] save error:", e.message);
    }
  }, [textbookId]);

  // 특정 페이지의 필기를 로드
  const loadDrawingForPage = useCallback(async (page: number) => {
    const data = await loadPdfDrawing(textbookId, page);
    console.log("[pdf-draw] load:", { page, hasData: !!data, len: data?.length ?? 0 });
    setDrawingImage(data);
    if (pencilKitRef.current) {
      try {
        if (data) {
          await pencilKitRef.current.setCanvasDataFromBase64(data);
        } else {
          await pencilKitRef.current.clearDrawing();
        }
      } catch (e: any) {
        console.log("[pdf-draw] load error:", e.message);
      }
    }
  }, [textbookId]);

  const handlePageChanged = useCallback(
    async (page: number, numberOfPages: number) => {
      if (drawingMode && currentPageRef.current !== page) {
        await saveCurrentDrawing();
      }
      setCurrentPage(page);
      currentPageRef.current = page;
      onPageChanged(page);
      // 드로잉 모드면 PencilKit에 로드, 아니면 이미지만 업데이트
      const data = await loadPdfDrawing(textbookId, page);
      setDrawingImage(data);
      if (drawingMode && pencilKitRef.current) {
        try {
          if (data) {
            await pencilKitRef.current.loadDrawingData(data);
          } else {
            await pencilKitRef.current.clear();
          }
        } catch {}
      }
    },
    [onPageChanged, drawingMode, saveCurrentDrawing, textbookId]
  );

  const handleToc = useCallback(async () => {
    setTocVisible(true);
    if (!tocLoaded) {
      try {
        const res = await api.get<ChapterItem[]>(`/pdf/${textbookId}/chapters`);
        setChapters(res.data);
        setTocLoaded(true);
      } catch (e: any) {
        console.log("[toc] error:", e.message);
      }
    }
  }, [textbookId, tocLoaded]);

  const handleChapterSelect = useCallback((page: number) => {
    setTocVisible(false);
    pdfRef.current?.setPage(page);
  }, []);

  const handleChapterGuide = useCallback(async (chapterId: string) => {
    setTocVisible(false);
    setChapterGuideVisible(true);
    setChapterGuideLoading(true);
    setChapterGuide(null);
    try {
      const res = await api.get<ChapterGuide>(`/pdf/${textbookId}/chapter-guide`, {
        params: { chapter_id: chapterId },
      });
      setChapterGuide(res.data);
    } catch (e: any) {
      console.log("[chapter-guide] error:", e.message);
    } finally {
      setChapterGuideLoading(false);
    }
  }, [textbookId]);

  const handleGuide = useCallback(async () => {
    const page = currentPageRef.current;
    setGuideVisible(true);
    setGuideLoading(true);
    setGuide(null);
    try {
      const res = await api.get<PageGuide>(`/pdf/${textbookId}/guide`, {
        params: { page },
      });
      setGuide(res.data);
    } catch (e: any) {
      console.log("[guide] error:", e.message);
    } finally {
      setGuideLoading(false);
    }
  }, [textbookId]);

  if (!token) {
    return (
      <View style={styles.container}>
        <Text style={styles.loadingText}>로딩 중...</Text>
      </View>
    );
  }

  const pdfUrl = `${API_BASE}/api/pdf/${textbookId}/file?token=${token}`;

  return (
    <View style={styles.container}>
      <View style={styles.topBar}>
        <Text style={styles.pageInfo}>
          {currentPage} / {totalPages}
        </Text>
        <TouchableOpacity onPress={onClose} style={styles.topBarBtn}>
          <Text style={styles.closeBtnText}>X</Text>
        </TouchableOpacity>
      </View>

      <View style={{ flex: 1 }}>
        <Pdf
          ref={pdfRef}
          source={{ uri: pdfUrl }}
          page={initialPage}
          style={styles.pdf}
          enablePaging
          horizontal
          onPageChanged={(page, numberOfPages) => handlePageChanged(page, numberOfPages)}
          onError={(error) => console.log("[pdf] error:", error)}
        />

        {/* Drawing mode: PencilKit active */}
        {drawingMode && PencilKitViewComponent && (
          <PencilKitViewComponent
            ref={pencilKitRef}
            style={styles.drawingOverlay}
            onDrawEnd={saveCurrentDrawing}
          />
        )}

        {/* View mode: show saved drawing as image */}
        {!drawingMode && drawingImage && (
          <Image
            source={{ uri: `data:image/png;base64,${drawingImage}` }}
            style={styles.drawingOverlay}
            pointerEvents="none"
          />
        )}
      </View>

      <View style={styles.bottomBar}>
        <TouchableOpacity onPress={handleToc} style={styles.bottomBarBtn}>
          <Text style={styles.bottomBarBtnText}>☰ 목차</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={handleGuide} style={styles.bottomBarBtn}>
          <Text style={styles.bottomBarBtnText}>📚 가이드</Text>
        </TouchableOpacity>
        <TouchableOpacity
          onPress={async () => {
            if (drawingMode) {
              await saveCurrentDrawing();
              // 저장 후 최신 이미지 로드 (필기 모드 꺼도 보이게)
              const data = await loadPdfDrawing(textbookId, currentPageRef.current);
              setDrawingImage(data);
            }
            setDrawingMode((prev) => {
              const next = !prev;
              if (next) {
                setTimeout(() => loadDrawingForPage(currentPageRef.current), 100);
              }
              return next;
            });
          }}
          style={[styles.bottomBarBtn, drawingMode && styles.bottomBarBtnActive]}
        >
          <Text style={[styles.bottomBarBtnText, drawingMode && styles.bottomBarBtnTextActive]}>
            ✏️ 필기
          </Text>
        </TouchableOpacity>
      </View>

      {/* Study Guide Bottom Sheet */}
      <Modal
        visible={guideVisible}
        transparent
        animationType="slide"
        onRequestClose={() => setGuideVisible(false)}
      >
        <TouchableOpacity
          style={styles.sheetOverlay}
          activeOpacity={1}
          onPress={() => setGuideVisible(false)}
        >
          <View style={styles.sheetDummy} />
        </TouchableOpacity>
        <View style={styles.sheet}>
          <TouchableOpacity style={styles.sheetHandleArea} onPress={() => { setGuideVisible(false); setTocVisible(false); setChapterGuideVisible(false); }}>
            <View style={styles.sheetHandle} />
          </TouchableOpacity>
          {guideLoading ? (
            <ActivityIndicator style={{ marginTop: 40 }} />
          ) : guide ? (
            <ScrollView style={styles.sheetContent} bounces={false}>
              <Text style={styles.sheetTitle}>{guide.topic}</Text>

              <Text style={styles.sectionHeader}>📌 핵심 암기</Text>
              {guide.key_points.map((point, i) => (
                <Text key={i} style={styles.listItem}>• {point}</Text>
              ))}

              <Text style={styles.sectionHeader}>✏️ 연습 과제</Text>
              {guide.exercises.map((ex, i) => (
                <Text key={i} style={styles.listItem}>• {ex}</Text>
              ))}

              <Text style={styles.sectionHeader}>🔗 연결</Text>
              <Text style={styles.bodyText}>{guide.connections}</Text>
            </ScrollView>
          ) : (
            <Text style={styles.errorText}>가이드를 불러올 수 없습니다.</Text>
          )}
        </View>
      </Modal>
      {/* TOC Modal */}
      <Modal
        visible={tocVisible}
        transparent
        animationType="slide"
        onRequestClose={() => setTocVisible(false)}
      >
        <TouchableOpacity
          style={styles.sheetOverlay}
          activeOpacity={1}
          onPress={() => setTocVisible(false)}
        >
          <View style={styles.sheetDummy} />
        </TouchableOpacity>
        <View style={styles.sheet}>
          <TouchableOpacity style={styles.sheetHandleArea} onPress={() => { setGuideVisible(false); setTocVisible(false); setChapterGuideVisible(false); }}>
            <View style={styles.sheetHandle} />
          </TouchableOpacity>
          <Text style={styles.sheetTitle}>목차</Text>
          <ScrollView style={styles.sheetContent} bounces={false}>
            {chapters.length === 0 ? (
              <Text style={styles.errorText}>목차 정보가 없습니다.</Text>
            ) : (
              chapters.map((ch) => (
                <View
                  key={ch.id}
                  style={[styles.tocItem, { paddingLeft: 12 + (ch.level - 1) * 16 }]}
                >
                  <TouchableOpacity style={{ flex: 1 }} onPress={() => handleChapterSelect(ch.pageStart)}>
                    <Text style={styles.tocTitle} numberOfLines={1}>{ch.title}</Text>
                  </TouchableOpacity>
                  <Text style={styles.tocPage}>p.{ch.pageStart}</Text>
                  {ch.level === 1 && (
                    <TouchableOpacity
                      style={styles.tocGuideBtn}
                      onPress={() => handleChapterGuide(ch.id)}
                    >
                      <Text style={styles.tocGuideBtnText}>📚</Text>
                    </TouchableOpacity>
                  )}
                </View>
              ))
            )}
          </ScrollView>
        </View>
      </Modal>
      {/* Chapter Guide Modal */}
      <Modal
        visible={chapterGuideVisible}
        transparent
        animationType="slide"
        onRequestClose={() => setChapterGuideVisible(false)}
      >
        <TouchableOpacity
          style={styles.sheetOverlay}
          activeOpacity={1}
          onPress={() => setChapterGuideVisible(false)}
        >
          <View style={styles.sheetDummy} />
        </TouchableOpacity>
        <View style={styles.sheet}>
          <TouchableOpacity style={styles.sheetHandleArea} onPress={() => { setGuideVisible(false); setTocVisible(false); setChapterGuideVisible(false); }}>
            <View style={styles.sheetHandle} />
          </TouchableOpacity>
          {chapterGuideLoading ? (
            <ActivityIndicator style={{ marginTop: 40 }} />
          ) : chapterGuide ? (
            <ScrollView style={styles.sheetContent} bounces={false}>
              <Text style={styles.sheetTitle}>{chapterGuide.title}</Text>
              <Text style={styles.bodyText}>{chapterGuide.topic}</Text>

              <Text style={styles.sectionHeader}>📌 핵심 개념</Text>
              {chapterGuide.key_concepts.map((item, i) => (
                <Text key={i} style={styles.listItem}>• {item}</Text>
              ))}

              <Text style={styles.sectionHeader}>📋 학습 순서</Text>
              {chapterGuide.study_order.map((item, i) => (
                <Text key={i} style={styles.listItem}>{i + 1}. {item}</Text>
              ))}

              <Text style={styles.sectionHeader}>⚠️ 자주 하는 실수</Text>
              {chapterGuide.common_mistakes.map((item, i) => (
                <Text key={i} style={styles.listItem}>• {item}</Text>
              ))}

              <Text style={styles.sectionHeader}>요약</Text>
              <Text style={styles.bodyText}>{chapterGuide.summary}</Text>
            </ScrollView>
          ) : (
            <Text style={styles.errorText}>챕터 가이드를 불러올 수 없습니다.</Text>
          )}
        </View>
      </Modal>
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
  },
  pageInfo: { fontSize: 13, color: "#333", flex: 1, textAlign: "center" },
  topBarBtn: { paddingHorizontal: 10, paddingVertical: 4 },
  guideBtnText: { fontSize: 18 },
  closeBtnText: { fontSize: 14, color: "#999" },
  pdf: { flex: 1 },
  bottomBar: {
    flexDirection: "row",
    justifyContent: "center",
    gap: 16,
    paddingVertical: 8,
    backgroundColor: "#fff",
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#ddd",
  },
  bottomBarBtn: {
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 8,
    backgroundColor: "#f0f0f0",
  },
  bottomBarBtnText: { fontSize: 13, color: "#333", fontWeight: "500" },
  bottomBarBtnActive: { backgroundColor: "#5856d6" },
  bottomBarBtnTextActive: { color: "#fff" },
  drawingOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: "transparent",
  },
  loadingText: { textAlign: "center", marginTop: 40, color: "#999" },

  // Bottom sheet
  sheetOverlay: { flex: 1 },
  sheetDummy: { flex: 1 },
  sheet: {
    backgroundColor: "#fff",
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    maxHeight: "60%",
    paddingBottom: 32,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: -2 },
    shadowOpacity: 0.1,
    shadowRadius: 8,
  },
  sheetHandle: {
    width: 36,
    height: 4,
    borderRadius: 2,
    backgroundColor: "#ddd",
    alignSelf: "center",
    marginTop: 8,
    marginBottom: 4,
  },
  sheetHandleArea: {
    alignItems: "center",
    paddingVertical: 8,
  },
  sheetContent: { paddingHorizontal: 20 },
  sheetTitle: { fontSize: 17, fontWeight: "700", color: "#1c1c1e", marginBottom: 16 },
  sectionHeader: { fontSize: 14, fontWeight: "600", color: "#555", marginTop: 14, marginBottom: 6 },
  listItem: { fontSize: 14, color: "#333", lineHeight: 20, marginLeft: 4, marginBottom: 4 },
  bodyText: { fontSize: 14, color: "#333", lineHeight: 20 },
  errorText: { textAlign: "center", marginTop: 40, color: "#999" },

  // TOC
  tocItem: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: 10,
    paddingRight: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#eee",
  },
  tocTitle: { flex: 1, fontSize: 14, color: "#1c1c1e" },
  tocPage: { fontSize: 12, color: "#999", marginLeft: 8 },
  tocGuideBtn: { marginLeft: 8, padding: 4 },
  tocGuideBtnText: { fontSize: 14 },
});
