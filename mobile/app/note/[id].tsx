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
import Toolbar from "../../src/components/Toolbar";
import { usePencilKitDrawing } from "../../src/hooks/usePencilKitDrawing";
import { requestFeedback } from "../../src/services/feedback";
import { saveFeedback, getFeedbacksByNoteId } from "../../src/services/database";
import { buildPreviousContext } from "../../src/services/contextBuilder";
import { getNoteById, linkTextbook } from "../../src/services/database";
import { pickAndUploadPdf } from "../../src/services/textbook";
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
  const [textbookPages, setTextbookPages] = useState<number>(0);
  const [pdfOpen, setPdfOpen] = useState(false);
  const [currentPage, setCurrentPage] = useState<number | null>(null);
  const { width: screenWidth, height: screenHeight } = useWindowDimensions();
  const isLandscape = screenWidth > screenHeight;
  const [canvasWidth, setCanvasWidth] = useState(screenWidth);
  const [canvasHeight, setCanvasHeight] = useState(screenHeight);

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

  const pk = usePencilKitDrawing(id);

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
      pk.saveNow();
    });
    return unsubscribe;
  }, [navigation, pk.saveNow]);

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
        language: "en",
        previousContext,
        textbookId: textbookId ?? undefined,
        currentPage: currentPage ?? undefined,
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
      };

      setFeedbackItems((prev) => [...prev, newItem]);

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
  }, [id, textbookId, currentPage, pk, feedbackItems, canvasWidth]);

  const handleFeedback = handleFeedbackPK;

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
          onLayout={(e) => {
            setCanvasWidth(e.nativeEvent.layout.width);
            setCanvasHeight(e.nativeEvent.layout.height);
          }}
        >
          <PencilKitCanvas
            pencilKitRef={pk.pencilKitRef}
            feedbackItems={feedbackItems}
            onDrawEnd={pk.onDrawEnd}
            onCanUndoChanged={pk.onCanUndoChanged}
            onCanRedoChanged={pk.onCanRedoChanged}
            onScroll={pk.onScroll}
            onStrokeCountChanged={pk.onStrokeCountChanged}
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
        penColor="#000000"
        penWidth={4}
        isEraser={false}
        canUndo={pk.canUndo}
        canRedo={pk.canRedo}
        onColorChange={() => {}}
        onWidthChange={() => {}}
        onEraserToggle={() => {}}
        onUndo={pk.undo}
        onRedo={pk.redo}
        onFeedback={handleFeedback}
        onTogglePdf={handleTogglePdf}
        pdfOpen={pdfOpen}
        hasTextbook={!!textbookId}
        mode="pencilkit"
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
