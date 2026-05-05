import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  View,
  StyleSheet,
  Alert,
  ActivityIndicator,
  Text,
  TouchableOpacity,
  useWindowDimensions,
  Platform,
} from "react-native";
import { useLocalSearchParams, useNavigation, useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import PencilKitCanvas from "../../src/components/PencilKitCanvas";
import PdfViewer from "../../src/components/PdfViewer";
import FloatingActionPill from "../../src/components/FloatingActionPill";
import { usePencilKitDrawing } from "../../src/hooks/usePencilKitDrawing";
import { requestFeedback } from "../../src/services/feedback";
import { saveFeedback, getFeedbacksByNoteId } from "../../src/services/database";
import { buildPreviousContext } from "../../src/services/contextBuilder";
import { getNoteById, linkTextbook, saveLastPage, savePdfOpen } from "../../src/services/database";
import { pickAndUploadPdf } from "../../src/services/textbook";
import Svg, { Path } from "react-native-svg";

let LiquidGlassView: any = null;
if (Platform.OS === "ios") {
  try {
    LiquidGlassView = require("expo-liquid-glass").default;
  } catch {}
}
import type { AIResponse, FeedbackResponse, FeedbackRenderItem } from "../../src/types";
import logger from "../../src/services/logger";

const USE_PENCILKIT = true;

const FEEDBACK_CARD_PADDING = 24;
const FEEDBACK_CARD_LINE_HEIGHT = 20;

export default function NoteScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const navigation = useNavigation();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const [feedbackItems, setFeedbackItems] = useState<FeedbackRenderItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [textbookId, setTextbookId] = useState<string | null>(null);
  const [textbookName, setTextbookName] = useState<string | null>(null);
  const [noteLanguage, setNoteLanguage] = useState("en");
  const [textbookPages, setTextbookPages] = useState<number>(0);
  const [pdfOpen, setPdfOpen] = useState(false);
  const [pdfInitialPage, setPdfInitialPage] = useState<number>(1);
  const currentPageRef = useRef<number | null>(null);
  const { width: screenWidth, height: screenHeight } = useWindowDimensions();
  const isLandscape = screenWidth > screenHeight;
  const [canvasWidth, setCanvasWidth] = useState(screenWidth);
  const [canvasHeight, setCanvasHeight] = useState(screenHeight);

  // 노트에 연결된 교재 로드
  useEffect(() => {
    if (!id) return;
    (async () => {
      const note = await getNoteById(id);
      if (note) {
        setNoteLanguage(note.language || "en");
        if (note.textbook_id) {
          setTextbookId(note.textbook_id);
          setTextbookName(note.textbook_name);
          setTextbookPages(note.textbook_pages ?? 0);
          const lp = note.last_page;
          const validPage = lp && lp >= 1 && lp <= (note.textbook_pages || 9999) ? lp : 1;
          setPdfInitialPage(validPage);
          currentPageRef.current = validPage;
          if (note.pdf_open) setPdfOpen(true);
          logger.info("textbook", "loaded", { id: note.textbook_id, name: note.textbook_name, pages: note.textbook_pages, lastPage: note.last_page });
        }
      }
    })();
  }, [id]);

  const pk = usePencilKitDrawing(id);

  // SQLite에서 피드백 로드
  useEffect(() => {
    if (!id) return;
    (async () => {
      const rows = await getFeedbacksByNoteId(id);
      const items: FeedbackRenderItem[] = rows.map((row) => {
        let text = row.content;
        let recognizedText: string | undefined;
        let feedback: string | undefined;
        let summary: string | undefined;
        try {
          const parsed = JSON.parse(row.content);
          if (parsed.feedback) {
            // 새 포맷 (AIResponse)
            recognizedText = parsed.recognized_text;
            feedback = parsed.feedback;
            summary = parsed.summary;
            text = [parsed.recognized_text, "", parsed.feedback, "", parsed.summary].join("\n");
          } else if (parsed.corrections) {
            // 이전 포맷 (FeedbackResponse) 호환
            text = [
              parsed.recognized_text,
              ...parsed.corrections.map(
                (c: any) => `${c.original} → ${c.corrected} (${c.reason})`
              ),
              parsed.summary,
            ].join("\n");
          }
        } catch {}
        const lines = text.split("\n").length;
        return {
          id: row.id,
          y: row.position_y,
          text,
          width: row.bbox_width || canvasWidth - 32,
          height: row.bbox_height || lines * FEEDBACK_CARD_LINE_HEIGHT + FEEDBACK_CARD_PADDING,
          recognizedText,
          feedback,
          summary,
        };
      });
      if (items.length > 0) {
        logger.info("feedback", "loaded from SQLite", {
          count: items.length,
          items: items.map(i => ({ id: i.id, y: i.y, height: i.height, width: i.width })),
        });
        setFeedbackItems(items);

        // 기존 피드백 위치에 맞춰 캔버스 확장
        const maxBottom = items.reduce((max, item) => Math.max(max, item.y + item.height + 200), 0);
        setTimeout(() => {
          const hasMethod = !!pk.pencilKitRef.current?.setContentHeight;
          logger.info("feedback", "setContentHeight", { maxBottom, hasMethod });
          if (hasMethod) {
            pk.pencilKitRef.current.setContentHeight(maxBottom);
          }
        }, 1000);
      }
    })();
  }, [id]);

  const [unmounting, setUnmounting] = useState(false);

  useEffect(() => {
    const unsubscribe = navigation.addListener("beforeRemove", (e) => {
      if (!unmounting) {
        e.preventDefault();
        pk.saveNow();
        setUnmounting(true);
        // PencilKit을 먼저 언마운트 후 네비게이션
        setTimeout(() => navigation.dispatch(e.data.action), 100);
      }
    });
    return unsubscribe;
  }, [navigation, pk.saveNow, unmounting]);

  const handleAttachTextbook = useCallback(async () => {
    try {
      const result = await pickAndUploadPdf(id!);
      if (result) {
        await linkTextbook(id!, result.id, result.fileName, result.totalPages);
        setTextbookId(result.id);
        setTextbookName(result.fileName);
        setTextbookPages(result.totalPages);
        Alert.alert("교재 연결", `${result.fileName} (${result.totalPages}p) 연결됨\n인덱싱 중...`);
      }
    } catch (e: any) {
      logger.error("textbook", "attach failed", { error: e?.message });
      Alert.alert("오류", e?.message ?? "교재 업로드에 실패했습니다.");
    }
  }, [id]);

  // ── PencilKit 피드백 핸들러 ──
  const handleFeedbackPK = useCallback(async () => {
    if (!pk.hasNewStrokes) {
      Alert.alert("알림", "새로 작성한 내용이 없습니다.");
      return;
    }

    // remount 전에 캔버스 데이터 확보: 바운딩 박스, 캡처, 저장 순서
    const drawingBounds = await pk.getDrawingBounds();
    const imageBase64 = await pk.captureFullBase64();
    await pk.saveNow();

    if (!imageBase64) {
      Alert.alert("오류", "캔버스 캡처에 실패했습니다.");
      return;
    }

    setLoading(true);
    try {
      const previousContext = await buildPreviousContext(id!);
      const result = await requestFeedback({
        imageBase64,
        noteId: id!,
        language: noteLanguage,
        previousContext,
        textbookId: textbookId ?? undefined,
        currentPage: currentPageRef.current ?? undefined,
      });

      const cardsMaxY = feedbackItems.reduce(
        (max, item) => Math.max(max, item.y + item.height), 0
      );
      const strokesMaxY = drawingBounds.y + drawingBounds.height;
      const maxY = Math.max(strokesMaxY, cardsMaxY);
      logger.info("feedback", "position calc", {
        drawingBounds,
        strokesMaxY,
        cardsMaxY,
        maxY,
      });
      const cardWidth = canvasWidth - 32;

      const feedbackText = [result.recognized_text, "", result.feedback, "", result.summary].join("\n");
      const lines = feedbackText.split("\n").length;
      const cardHeight = lines * FEEDBACK_CARD_LINE_HEIGHT + FEEDBACK_CARD_PADDING;

      const newItem: FeedbackRenderItem = {
        id: Date.now().toString(),
        y: maxY + FEEDBACK_CARD_PADDING,
        text: feedbackText,
        width: cardWidth,
        height: cardHeight,
        recognizedText: result.recognized_text,
        feedback: result.feedback,
        summary: result.summary,
      };

      setFeedbackItems((prev) => [...prev, newItem]);

      // 피드백 카드 끝까지 캔버스 확장
      const requiredHeight = newItem.y + cardHeight + 200;
      if (pk.pencilKitRef.current?.setContentHeight) {
        await pk.pencilKitRef.current.setContentHeight(requiredHeight);
      }

      await saveFeedback(id!, JSON.stringify(result), { x: 16, y: newItem.y }, {
        x: 16, y: newItem.y, width: cardWidth, height: cardHeight,
      });
      pk.markFeedbackPoint();
    } catch (e: any) {
      const msg = e?.response?.data?.detail ?? e?.message ?? "알 수 없는 오류";
      Alert.alert("피드백 오류", msg);
    } finally {
      setLoading(false);
    }
  }, [id, textbookId, pk, feedbackItems, canvasWidth]);

  const handleFeedback = handleFeedbackPK;

  const handleTogglePdf = useCallback(() => {
    if (!textbookId) {
      handleAttachTextbook();
      return;
    }
    setPdfOpen((prev) => {
      const next = !prev;
      savePdfOpen(id, next);
      return next;
    });
  }, [id, textbookId, handleAttachTextbook]);

  return (
    <View style={styles.container}>
      {/* 스플릿 뷰: landscape=좌우, portrait=상하 */}
      <View style={[styles.splitContainer, pdfOpen && !isLandscape && styles.splitContainerColumn]}>
        {pdfOpen && textbookId && (
          <View style={isLandscape ? styles.pdfPanel : styles.pdfPanelRow}>
            <PdfViewer
              textbookId={textbookId}
              totalPages={textbookPages}
              initialPage={pdfInitialPage}
              onPageChanged={(page) => {
                currentPageRef.current = page;
                saveLastPage(id, page);
              }}
              onClose={() => { setPdfOpen(false); savePdfOpen(id, false); }}
            />
          </View>
        )}
        <View
          style={[pdfOpen ? styles.canvasSplit : styles.canvasFull, { overflow: "hidden" }]}
          onLayout={(e) => {
            setCanvasWidth(e.nativeEvent.layout.width);
            setCanvasHeight(e.nativeEvent.layout.height);
          }}
        >
          {!unmounting && (
            <PencilKitCanvas
              pencilKitRef={pk.pencilKitRef}
              feedbackItems={feedbackItems}
              onDrawEnd={pk.onDrawEnd}
              onCanUndoChanged={pk.onCanUndoChanged}
              onCanRedoChanged={pk.onCanRedoChanged}
              onScroll={pk.onScroll}
              onStrokeCountChanged={pk.onStrokeCountChanged}
            />
          )}
        </View>
      </View>

      {/* Floating back button */}
      {LiquidGlassView ? (
        <LiquidGlassView style={[styles.backFab, { top: 12 + insets.top }]} radius={18}>
          <TouchableOpacity
            style={styles.backFabInner}
            onPress={() => router.back()}
            activeOpacity={0.7}
          >
            <Svg width={20} height={20} viewBox="0 0 24 24" fill="none" stroke="#1c1c1e" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round">
              <Path d="M15 18l-6-6 6-6" />
            </Svg>
          </TouchableOpacity>
        </LiquidGlassView>
      ) : (
        <TouchableOpacity
          style={[styles.backFab, styles.backFabFallback, { top: 12 + insets.top }]}
          onPress={() => router.back()}
          activeOpacity={0.7}
        >
          <Svg width={20} height={20} viewBox="0 0 24 24" fill="none" stroke="#1c1c1e" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round">
            <Path d="M15 18l-6-6 6-6" />
          </Svg>
        </TouchableOpacity>
      )}

      {/* Loading state is shown in FAB pill spinner */}

      {/* Floating action pill */}
      <FloatingActionPill
        onTogglePdf={handleTogglePdf}
        onFeedback={handleFeedback}
        pdfOpen={pdfOpen}
        loading={loading}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff" },
  splitContainer: { flex: 1, flexDirection: "row" },
  splitContainerColumn: { flexDirection: "column" },
  canvasFull: { flex: 1 },
  canvasSplit: { flex: 1, flexBasis: 0 },
  pdfPanel: { flex: 1, flexBasis: 0, borderRightWidth: StyleSheet.hairlineWidth, borderRightColor: "#e5e5ea" },
  pdfPanelRow: { flex: 1, flexBasis: 0, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: "#e5e5ea" },
  backFab: {
    position: "absolute",
    left: 12,
    zIndex: 20,
    width: 36,
    height: 36,
    borderRadius: 18,
  },
  backFabInner: {
    width: 36,
    height: 36,
    justifyContent: "center",
    alignItems: "center",
  },
  backFabFallback: {
    backgroundColor: "rgba(255,255,255,0.85)",
    borderWidth: 1,
    borderColor: "rgba(0,0,0,0.08)",
    justifyContent: "center",
    alignItems: "center",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.08,
    shadowRadius: 4,
    elevation: 4,
  },
  loadingBar: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 8,
    backgroundColor: "#e8f2ff",
    gap: 8,
  },
  loadingText: {
    fontSize: 13,
    color: "#4a5568",
  },
});
