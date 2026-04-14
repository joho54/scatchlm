import React, { useCallback, useEffect, useRef, useState } from "react";
import { View, StyleSheet, Alert, ActivityIndicator, Text } from "react-native";
import { useLocalSearchParams, useNavigation } from "expo-router";

import DrawingCanvas, {
  DrawingCanvasHandle,
} from "../../src/components/DrawingCanvas";
import Toolbar from "../../src/components/Toolbar";
import FeedbackOverlay from "../../src/components/FeedbackOverlay";
import { useDrawing } from "../../src/hooks/useDrawing";
import { requestFeedback } from "../../src/services/feedback";
import { saveFeedback } from "../../src/services/database";
import { buildPreviousContext } from "../../src/services/contextBuilder";
import type { FeedbackResponse } from "../../src/types";
import logger from "../../src/services/logger";

export default function NoteScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  logger.info("note", "NoteScreen render", { noteId: id });
  const navigation = useNavigation();
  const canvasRef = useRef<DrawingCanvasHandle>(null);
  const [feedback, setFeedback] = useState<FeedbackResponse | null>(null);
  const [loading, setLoading] = useState(false);

  logger.info("note", "before useDrawing");
  const {
    strokes,
    currentStroke,
    penColor,
    penWidth,
    isEraser,
    canUndo,
    canRedo,
    setPenColor,
    setPenWidth,
    toggleEraser,
    onStrokeStart,
    onStrokeMove,
    onStrokeEnd,
    undo,
    redo,
    saveNow,
  } = useDrawing(id);
  logger.info("note", "after useDrawing", { strokeCount: strokes.length });

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
    logger.info("feedback", "capture result", { hasBase64: !!imageBase64, length: imageBase64?.length });
    if (!imageBase64) {
      Alert.alert("오류", "캔버스 캡처에 실패했습니다.");
      return;
    }

    setLoading(true);
    setFeedback(null);

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
      logger.info("feedback", "feedback received", { text: result.recognized_text?.slice(0, 50) });
      setFeedback(result);

      await saveFeedback(
        id!,
        JSON.stringify(result),
        { x: 0, y: 0 },
        { x: 0, y: 0, width: 0, height: 0 }
      );
      logger.info("feedback", "saved to SQLite");
    } catch (e: any) {
      const msg = e?.response?.data?.detail ?? e?.message ?? "알 수 없는 오류";
      logger.error("feedback", "request failed", { error: msg });
      Alert.alert("피드백 오류", msg);
    } finally {
      setLoading(false);
    }
  }, [strokes, id]);

  logger.info("note", "before render JSX");
  return (
    <View style={styles.container}>
      <DrawingCanvas
        ref={canvasRef}
        strokes={strokes}
        currentStroke={currentStroke}
        onStrokeStart={onStrokeStart}
        onStrokeMove={onStrokeMove}
        onStrokeEnd={onStrokeEnd}
      />

      {loading && (
        <View style={styles.loadingBar}>
          <ActivityIndicator size="small" color="#007AFF" />
          <Text style={styles.loadingText}>피드백을 받고 있습니다...</Text>
        </View>
      )}

      {feedback && <FeedbackOverlay feedback={feedback} />}

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
