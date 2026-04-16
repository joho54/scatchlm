import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  View,
  StyleSheet,
  Alert,
  ActivityIndicator,
  Text,
  TouchableOpacity,
  useWindowDimensions,
} from "react-native";
import { useLocalSearchParams, useNavigation, useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import DrawingCanvas, {
  DrawingCanvasHandle,
} from "../../src/components/DrawingCanvas";
import PdfViewer from "../../src/components/PdfViewer";
import Toolbar from "../../src/components/Toolbar";
import { useDrawing } from "../../src/hooks/useDrawing";
import { requestFeedback } from "../../src/services/feedback";
import { saveFeedback, getFeedbacksByNoteId } from "../../src/services/database";
import { buildPreviousContext } from "../../src/services/contextBuilder";
import { getNoteById, linkTextbook } from "../../src/services/database";
import { pickAndUploadPdf } from "../../src/services/textbook";
import type { AIResponse, FeedbackResponse, FeedbackRenderItem } from "../../src/types";
import logger from "../../src/services/logger";

const FEEDBACK_CARD_PADDING = 24;
const FEEDBACK_CARD_LINE_HEIGHT = 20;

export default function NoteScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const navigation = useNavigation();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const canvasRef = useRef<DrawingCanvasHandle>(null);
  const [feedbackItems, setFeedbackItems] = useState<FeedbackRenderItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [textbookId, setTextbookId] = useState<string | null>(null);
  const [textbookName, setTextbookName] = useState<string | null>(null);
  const [textbookPages, setTextbookPages] = useState<number>(0);
  const [pdfOpen, setPdfOpen] = useState(false);
  const [currentPage, setCurrentPage] = useState<number | null>(null);
  const { width: screenWidth, height: screenHeight } = useWindowDimensions();
  const isLandscape = screenWidth > screenHeight;
  const [canvasWidth, setCanvasWidth] = useState(screenWidth);

  // 노트에 연결된 교재 로드
  useEffect(() => {
    if (!id) return;
    (async () => {
      const note = await getNoteById(id);
      if (note?.textbook_id) {
        setTextbookId(note.textbook_id);
        setTextbookName(note.textbook_name);
        setTextbookPages(note.textbook_pages ?? 0);
        logger.info("textbook", "loaded", { id: note.textbook_id, name: note.textbook_name, pages: note.textbook_pages });
      }
    })();
  }, [id]);

  const {
    strokes,
    currentStroke,
    penColor,
    penWidth,
    isEraser,
    canUndo,
    canRedo,
    scrollOffset,
    setPenColor,
    setPenWidth,
    toggleEraser,
    onStrokeStart,
    onStrokeMove,
    onStrokeEnd,
    onScroll,
    undo,
    redo,
    saveNow,
    getStrokesMaxY,
    getNewStrokes,
    getNewStrokesBounds,
    markFeedbackPoint,
  } = useDrawing(id);

  // SQLite에서 피드백 로드
  useEffect(() => {
    if (!id) return;
    (async () => {
      const rows = await getFeedbacksByNoteId(id);
      const items: FeedbackRenderItem[] = rows.map((row) => {
        let text = row.content;
        try {
          const parsed = JSON.parse(row.content);
          if (parsed.feedback) {
            // 새 포맷 (AIResponse)
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
        };
      });
      if (items.length > 0) {
        logger.info("feedback", "loaded from SQLite", { count: items.length });
        setFeedbackItems(items);
      }
    })();
  }, [id]);

  useEffect(() => {
    const unsubscribe = navigation.addListener("beforeRemove", () => {
      saveNow();
    });
    return unsubscribe;
  }, [navigation, saveNow]);

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

  const handleFeedback = useCallback(async () => {
    const newStrokes = getNewStrokes();
    logger.info("feedback", "handleFeedback called", {
      totalStrokes: strokes.length,
      newStrokes: newStrokes.length,
    });

    if (newStrokes.length === 0) {
      Alert.alert("알림", "새로 작성한 내용이 없습니다.");
      return;
    }

    const bounds = getNewStrokesBounds();
    if (!bounds) {
      Alert.alert("오류", "필기 영역을 계산할 수 없습니다.");
      return;
    }

    logger.info("feedback", "capturing new strokes", {
      bounds,
      strokeCount: newStrokes.length,
    });

    const imageBase64 = canvasRef.current?.captureNewStrokesBase64(newStrokes, bounds);
    logger.info("feedback", "capture result", {
      hasBase64: !!imageBase64,
      length: imageBase64?.length,
    });
    if (!imageBase64) {
      Alert.alert("오류", "캔버스 캡처에 실패했습니다.");
      return;
    }

    setLoading(true);

    try {
      logger.info("feedback", "building context");
      const previousContext = await buildPreviousContext(id!);
      logger.info("feedback", "requesting feedback", { hasContext: !!previousContext });
      const result = await requestFeedback({
        imageBase64,
        noteId: id!,
        language: "en",
        previousContext,
        textbookId: textbookId ?? undefined,
        currentPage: currentPage ?? undefined,
      });
      logger.info("feedback", "feedback received", {
        text: result.recognized_text?.slice(0, 50),
      });

      // 피드백 위치 = (스트로크 + 기존 피드백 카드) maxY + 24px 아래
      const strokesMaxY = getStrokesMaxY();
      const cardsMaxY = feedbackItems.reduce(
        (max, item) => Math.max(max, item.y + item.height),
        0
      );
      const maxY = Math.max(strokesMaxY, cardsMaxY);
      const cardWidth = canvasWidth - 32;

      const feedbackText = [
        result.recognized_text,
        "",
        result.feedback,
        "",
        result.summary,
      ].join("\n");

      const lines = feedbackText.split("\n").length;
      const cardHeight = lines * FEEDBACK_CARD_LINE_HEIGHT + FEEDBACK_CARD_PADDING;

      const newItem: FeedbackRenderItem = {
        id: Date.now().toString(),
        y: maxY + FEEDBACK_CARD_PADDING,
        text: feedbackText,
        width: cardWidth,
        height: cardHeight,
      };

      logger.info("feedback", "feedbackItem created", {
        y: newItem.y,
        width: newItem.width,
        height: newItem.height,
        textLength: newItem.text.length,
        textPreview: newItem.text.slice(0, 80),
      });

      setFeedbackItems((prev) => {
        const updated = [...prev, newItem];
        logger.info("feedback", "feedbackItems updated", { count: updated.length });
        return updated;
      });

      // SQLite에 실제 좌표로 저장
      await saveFeedback(id!, JSON.stringify(result), { x: 16, y: newItem.y }, {
        x: 16,
        y: newItem.y,
        width: cardWidth,
        height: cardHeight,
      });
      logger.info("feedback", "saved to SQLite", { y: newItem.y });
      markFeedbackPoint();
      logger.info("feedback", "marked feedback point", { strokeCount: strokes.length });
    } catch (e: any) {
      const msg = e?.response?.data?.detail ?? e?.message ?? "알 수 없는 오류";
      logger.error("feedback", "request failed", { error: msg });
      Alert.alert("피드백 오류", msg);
    } finally {
      setLoading(false);
    }
  }, [strokes, id, textbookId, currentPage, getStrokesMaxY, getNewStrokes, getNewStrokesBounds, markFeedbackPoint, canvasWidth]);

  const handleTogglePdf = useCallback(() => {
    if (!textbookId) {
      handleAttachTextbook();
      return;
    }
    setPdfOpen((prev) => !prev);
  }, [textbookId, handleAttachTextbook]);

  return (
    <View style={styles.container}>
      <View style={[styles.topBar, { paddingTop: insets.top }]}>
        <TouchableOpacity onPress={() => router.back()}>
          <Text style={styles.backText}>{"<-"} 목록</Text>
        </TouchableOpacity>
        {textbookName && (
          <Text style={styles.textbookLabel} numberOfLines={1}>
            {textbookName}
          </Text>
        )}
      </View>

      {/* 스플릿 뷰: landscape=좌우, portrait=상하 */}
      <View style={[styles.splitContainer, pdfOpen && !isLandscape && styles.splitContainerColumn]}>
        {pdfOpen && textbookId && (
          <View style={isLandscape ? styles.pdfPanel : styles.pdfPanelRow}>
            <PdfViewer
              textbookId={textbookId}
              totalPages={textbookPages}
              onPageChanged={setCurrentPage}
              onClose={() => setPdfOpen(false)}
            />
          </View>
        )}
        <View
          style={pdfOpen ? styles.canvasSplit : styles.canvasFull}
          onLayout={(e) => setCanvasWidth(e.nativeEvent.layout.width)}
        >
          <DrawingCanvas
            key={`${pdfOpen}-${isLandscape}`}
            ref={canvasRef}
            strokes={strokes}
            currentStroke={currentStroke}
            scrollOffset={scrollOffset}
            feedbackItems={feedbackItems}
            onStrokeStart={onStrokeStart}
            onStrokeMove={onStrokeMove}
            onStrokeEnd={onStrokeEnd}
            onScroll={onScroll}
          />
        </View>
      </View>

      {loading && (
        <View style={styles.loadingBar}>
          <ActivityIndicator size="small" color="#007AFF" />
          <Text style={styles.loadingText}>피드백을 받고 있습니다...</Text>
        </View>
      )}

      <Toolbar
        penColor={penColor}
        penWidth={penWidth}
        isEraser={isEraser}
        canUndo={canUndo}
        canRedo={canRedo}
        onColorChange={setPenColor}
        onWidthChange={setPenWidth}
        onEraserToggle={toggleEraser}
        onUndo={undo}
        onRedo={redo}
        onFeedback={handleFeedback}
        onTogglePdf={handleTogglePdf}
        pdfOpen={pdfOpen}
        hasTextbook={!!textbookId}
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
  pdfPanel: { flex: 1, flexBasis: 0, borderRightWidth: StyleSheet.hairlineWidth, borderRightColor: "#ddd" },
  pdfPanelRow: { flex: 1, flexBasis: 0, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: "#ddd" },
  topBar: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: "#f8f8f8",
  },
  backText: { fontSize: 16, color: "#007AFF" },
  textbookLabel: {
    fontSize: 13,
    color: "#4F46E5",
    maxWidth: "60%",
  },
  loadingBar: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 8,
    backgroundColor: "#EBF4FF",
    gap: 8,
  },
  loadingText: {
    fontSize: 14,
    color: "#4A5568",
  },
});
