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

import DrawingCanvas, {
  DrawingCanvasHandle,
} from "../../src/components/DrawingCanvas";
import Toolbar from "../../src/components/Toolbar";
import { useDrawing } from "../../src/hooks/useDrawing";
import { requestFeedback } from "../../src/services/feedback";
import { saveFeedback } from "../../src/services/database";
import { buildPreviousContext } from "../../src/services/contextBuilder";
import type { FeedbackResponse, FeedbackRenderItem } from "../../src/types";
import logger from "../../src/services/logger";

const FEEDBACK_CARD_PADDING = 24;
const FEEDBACK_CARD_LINE_HEIGHT = 20;

export default function NoteScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const navigation = useNavigation();
  const router = useRouter();
  const canvasRef = useRef<DrawingCanvasHandle>(null);
  const [feedbackItems, setFeedbackItems] = useState<FeedbackRenderItem[]>([]);
  const [loading, setLoading] = useState(false);
  const { width: screenWidth } = useWindowDimensions();

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
  } = useDrawing(id);

  useEffect(() => {
    const unsubscribe = navigation.addListener("beforeRemove", () => {
      saveNow();
    });
    return unsubscribe;
  }, [navigation, saveNow]);

  const handleFeedback = useCallback(async () => {
    logger.info("feedback", "handleFeedback called", { strokeCount: strokes.length });
    if (strokes.length === 0) {
      Alert.alert("알림", "먼저 캔버스에 내용을 작성해주세요.");
      return;
    }

    logger.info("feedback", "capturing canvas");
    const imageBase64 = await canvasRef.current?.captureBase64();
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
      });
      logger.info("feedback", "feedback received", {
        text: result.recognized_text?.slice(0, 50),
      });

      // 피드백 위치 = 스트로크 maxY + 24px 아래
      const maxY = getStrokesMaxY();
      const cardWidth = screenWidth - 32;
      const lines = result.corrections.length + 2; // corrections + recognized + summary
      const cardHeight = lines * FEEDBACK_CARD_LINE_HEIGHT + FEEDBACK_CARD_PADDING;

      const feedbackText = [
        result.recognized_text,
        ...result.corrections.map(
          (c) => `${c.original} → ${c.corrected} (${c.reason})`
        ),
        result.summary,
      ].join("\n");

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
    } catch (e: any) {
      const msg = e?.response?.data?.detail ?? e?.message ?? "알 수 없는 오류";
      logger.error("feedback", "request failed", { error: msg });
      Alert.alert("피드백 오류", msg);
    } finally {
      setLoading(false);
    }
  }, [strokes, id, getStrokesMaxY, screenWidth]);

  return (
    <View style={styles.container}>
      <TouchableOpacity style={styles.backBtn} onPress={() => router.back()}>
        <Text style={styles.backText}>← 목록</Text>
      </TouchableOpacity>
      <DrawingCanvas
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

      {/* 진단용: RN Text로 피드백 데이터 확인 */}
      {feedbackItems.length > 0 && (
        <View style={styles.debugFeedback}>
          <Text style={{ fontSize: 12 }}>{feedbackItems[feedbackItems.length - 1].text.slice(0, 100)}</Text>
        </View>
      )}

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
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff" },
  backBtn: { paddingHorizontal: 16, paddingVertical: 10, backgroundColor: "#f8f8f8" },
  backText: { fontSize: 16, color: "#007AFF" },
  debugFeedback: { padding: 8, backgroundColor: "#FFFDE7", borderTopWidth: 1, borderColor: "#ddd" },
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
