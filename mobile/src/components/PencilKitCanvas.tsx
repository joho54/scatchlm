import React, { useCallback, useMemo, useRef } from "react";
import { StyleSheet, View, Text, Platform, Animated, useWindowDimensions } from "react-native";
import type { FeedbackRenderItem } from "../types";
import FeedbackCard from "./FeedbackCard";

// iOS only — expo-pencilkit-ui
let PencilKitViewComponent: any = null;
if (Platform.OS === "ios") {
  try {
    const mod = require("expo-pencilkit-ui");
    PencilKitViewComponent = mod.PencilKitView ?? mod.default;
  } catch {}
}

interface PencilKitCanvasProps {
  pencilKitRef: React.RefObject<any>;
  feedbackItems: FeedbackRenderItem[];
  onDrawEnd: () => void;
  onCanUndoChanged: (e: any) => void;
  onCanRedoChanged: (e: any) => void;
  onScroll: (e: any) => void;
  onStrokeCountChanged: (e: any) => void;
}

export default function PencilKitCanvas({
  pencilKitRef,
  feedbackItems,
  onDrawEnd,
  onCanUndoChanged,
  onCanRedoChanged,
  onScroll,
  onStrokeCountChanged,
}: PencilKitCanvasProps) {
  // Animated.Value로 스크롤 오프셋 관리 — setState 리렌더 회피
  const scrollY = useRef(new Animated.Value(0)).current;

  const handleScroll = useCallback(
    (e: any) => {
      const offsetY = e.nativeEvent.contentOffsetY;
      scrollY.setValue(-offsetY);
      // 부모 훅에도 전달 (피드백 위치 계산용)
      onScroll(e);
    },
    [onScroll, scrollY]
  );

  if (!PencilKitViewComponent) {
    return (
      <View style={styles.fallback}>
        <Text style={styles.fallbackText}>PencilKit is iOS only</Text>
      </View>
    );
  }

  // 노트 줄무늬 배경 생성 (40px 간격)
  const { height: screenHeight } = useWindowDimensions();
  const ruledLines = useMemo(() => {
    const lineCount = Math.ceil((screenHeight * 3) / 40); // 스크롤 영역 대비 충분한 줄
    return Array.from({ length: lineCount }, (_, i) => (
      <View key={i} style={[styles.ruledLine, { top: 40 * (i + 1) }]} />
    ));
  }, [screenHeight]);

  return (
    <View style={styles.container}>
      {/* 노트 줄무늬 배경 — 스크롤 동기화 */}
      <Animated.View
        style={[styles.ruledLinesContainer, { transform: [{ translateY: scrollY }] }]}
        pointerEvents="none"
      >
        {ruledLines}
      </Animated.View>

      {/* PencilKit 네이티브 캔버스 */}
      <PencilKitViewComponent
        ref={pencilKitRef}
        style={StyleSheet.absoluteFill}
        onDrawEnd={onDrawEnd}
        onCanUndoChanged={onCanUndoChanged}
        onCanRedoChanged={onCanRedoChanged}
        onScroll={handleScroll}
        onStrokeCountChanged={onStrokeCountChanged}
      />

      {/* 피드백 카드 오버레이 — Animated.View로 translateY 적용 */}
      {feedbackItems.length > 0 && (
        <Animated.View
          style={[styles.overlay, { transform: [{ translateY: scrollY }] }]}
          pointerEvents="none"
        >
          {feedbackItems.map((item) => (
            <FeedbackCard
              key={item.id}
              recognizedText={item.recognizedText}
              feedback={item.feedback}
              summary={item.summary}
              text={item.text}
              y={item.y}
              width={item.width}
            />
          ))}
        </Animated.View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff", overflow: "hidden" },
  ruledLinesContainer: {
    ...StyleSheet.absoluteFillObject,
    opacity: 0.5,
  },
  ruledLine: {
    position: "absolute",
    left: 0,
    right: 0,
    height: 1,
    backgroundColor: "#e8ecf0",
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
  },
  fallback: { flex: 1, justifyContent: "center", alignItems: "center" },
  fallbackText: { color: "#999", fontSize: 16 },
});
