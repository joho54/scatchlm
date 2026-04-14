import React, { forwardRef, useImperativeHandle, useRef } from "react";
import { StyleSheet, View, useWindowDimensions } from "react-native";
import {
  Canvas,
  Group,
  Path,
  Paragraph,
  RoundedRect,
  Skia,
  SkPath,
  makeImageFromView,
} from "@shopify/react-native-skia";
import {
  Gesture,
  GestureDetector,
  GestureHandlerRootView,
} from "react-native-gesture-handler";
import { runOnJS, useSharedValue } from "react-native-reanimated";
import type { FeedbackRenderItem } from "../types";
import logger from "../services/logger";

export interface StrokeData {
  path: SkPath;
  color: string;
  width: number;
}

export interface DrawingCanvasHandle {
  capture: () => Promise<Uint8Array | null>;
  captureBase64: () => Promise<string | null>;
}

interface DrawingCanvasProps {
  strokes: StrokeData[];
  currentStroke: StrokeData | null;
  scrollOffset: number;
  feedbackItems: FeedbackRenderItem[];
  onStrokeStart: (x: number, y: number) => void;
  onStrokeMove: (x: number, y: number) => void;
  onStrokeEnd: () => void;
  onScroll: (deltaY: number) => void;
}

const VIEWPORT_PADDING = 200; // 뷰포트 밖 컬링 여유

const DrawingCanvas = forwardRef<DrawingCanvasHandle, DrawingCanvasProps>(
  (
    {
      strokes,
      currentStroke,
      scrollOffset,
      feedbackItems,
      onStrokeStart,
      onStrokeMove,
      onStrokeEnd,
      onScroll,
    },
    ref
  ) => {
    const viewRef = useRef<View>(null);
    const { height: screenHeight } = useWindowDimensions();

    if (feedbackItems.length > 0) {
      logger.info("canvas", "rendering feedbackItems", {
        count: feedbackItems.length,
        items: feedbackItems.map((i) => ({ id: i.id, y: i.y, textLen: i.text.length })),
      });
    }

    useImperativeHandle(ref, () => ({
      capture: async () => {
        if (!viewRef.current) return null;
        try {
          const image = await makeImageFromView(viewRef);
          if (!image) return null;
          const encoded = image.encodeToBase64();
          const binary = atob(encoded);
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
          }
          return bytes;
        } catch {
          return null;
        }
      },
      captureBase64: async () => {
        if (!viewRef.current) return null;
        try {
          const image = await makeImageFromView(viewRef);
          if (!image) return null;
          return image.encodeToBase64();
        } catch {
          return null;
        }
      },
    }));

    // 뷰포트 내 스트로크만 필터링 (컬링)
    const viewportTop = scrollOffset - VIEWPORT_PADDING;
    const viewportBottom = scrollOffset + screenHeight + VIEWPORT_PADDING;

    const visibleStrokes = strokes.filter((stroke) => {
      const bounds = stroke.path.getBounds();
      return bounds.y + bounds.height >= viewportTop && bounds.y <= viewportBottom;
    });

    // 제스처: Apple Pencil (pointerType=1) → 드로잉, 손가락 (pointerType=0) → 스크롤
    const isDrawing = useSharedValue(false);
    const lastTranslationY = useSharedValue(0);

    const pan = Gesture.Pan()
      .minDistance(0)
      .onBegin((e) => {
        "worklet";
        // @ts-ignore - pointerType: 0=touch, 1=stylus, 2=mouse
        const pType = e.pointerType;
        isDrawing.value = pType === 1;
        lastTranslationY.value = 0;
        if (isDrawing.value) {
          runOnJS(onStrokeStart)(e.x, e.y);
        }
      })
      .onUpdate((e) => {
        "worklet";
        if (isDrawing.value) {
          runOnJS(onStrokeMove)(e.x, e.y);
        } else {
          const delta = e.translationY - lastTranslationY.value;
          lastTranslationY.value = e.translationY;
          runOnJS(onScroll)(-delta);
        }
      })
      .onEnd(() => {
        "worklet";
        if (isDrawing.value) {
          runOnJS(onStrokeEnd)();
        }
      })
      .onFinalize(() => {
        "worklet";
        if (isDrawing.value) {
          runOnJS(onStrokeEnd)();
        }
        isDrawing.value = false;
      });

    const gesture = pan;

    // 피드백 Paragraph 빌드
    const feedbackParagraphs = feedbackItems.map((item) => {
      const para = Skia.ParagraphBuilder.Make()
        .pushStyle({ color: Skia.Color("#1E293B"), fontSize: 14 })
        .addText(item.text)
        .pop()
        .build();
      return { item, para };
    });

    return (
      <GestureHandlerRootView style={styles.container}>
        <GestureDetector gesture={gesture}>
          <View ref={viewRef} style={styles.canvas} collapsable={false}>
            <Canvas style={StyleSheet.absoluteFill}>
              <Group transform={[{ translateY: -scrollOffset }]}>
                {/* 스트로크 렌더링 (뷰포트 컬링 적용) */}
                {visibleStrokes.map((stroke, index) => (
                  <Path
                    key={index}
                    path={stroke.path}
                    color={stroke.color}
                    style="stroke"
                    strokeWidth={stroke.width}
                    strokeCap="round"
                    strokeJoin="round"
                  />
                ))}
                {currentStroke && (
                  <Path
                    path={currentStroke.path}
                    color={currentStroke.color}
                    style="stroke"
                    strokeWidth={currentStroke.width}
                    strokeCap="round"
                    strokeJoin="round"
                  />
                )}

                {/* 피드백 인라인 카드 렌더링 */}
                {feedbackParagraphs.map(({ item, para }) => (
                  <Group key={item.id}>
                    <Paragraph
                      paragraph={para}
                      x={24}
                      y={item.y + 8}
                      width={item.width - 16}
                    />
                  </Group>
                ))}
              </Group>
            </Canvas>
          </View>
        </GestureDetector>
      </GestureHandlerRootView>
    );
  }
);

DrawingCanvas.displayName = "DrawingCanvas";

export default DrawingCanvas;

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff" },
  canvas: { flex: 1 },
});
