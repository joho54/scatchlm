import React, { useCallback, useRef } from "react";
import { StyleSheet, View, Text, Platform, Animated } from "react-native";
import type { FeedbackRenderItem } from "../types";

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

  return (
    <View style={styles.container}>
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
            <View
              key={item.id}
              style={[
                styles.feedbackCard,
                {
                  top: item.y,
                  width: item.width,
                  minHeight: item.height,
                },
              ]}
            >
              <Text style={styles.feedbackText}>{item.text}</Text>
            </View>
          ))}
        </Animated.View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff", overflow: "hidden" },
  overlay: {
    ...StyleSheet.absoluteFillObject,
  },
  feedbackCard: {
    position: "absolute",
    left: 16,
    backgroundColor: "rgba(255, 255, 255, 0.95)",
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E2E8F0",
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  feedbackText: {
    fontSize: 14,
    lineHeight: 20,
    color: "#1E293B",
  },
  fallback: { flex: 1, justifyContent: "center", alignItems: "center" },
  fallbackText: { color: "#999", fontSize: 16 },
});
