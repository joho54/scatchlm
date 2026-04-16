import React, { forwardRef, useImperativeHandle, useRef, useState } from "react";
import { StyleSheet, View, useWindowDimensions } from "react-native";
import {
  Canvas,
  Group,
  Path,
  Paragraph,
  Rect,
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


export interface StrokeData {
  path: SkPath;
  color: string;
  width: number;
}

export interface DrawingCanvasHandle {
  capture: () => Promise<Uint8Array | null>;
  captureBase64: () => Promise<string | null>;
  captureNewStrokesBase64: (
    newStrokes: StrokeData[],
    bounds: { x: number; y: number; width: number; height: number }
  ) => string | null;
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
    const { width: screenWidth, height: screenHeight } = useWindowDimensions();
    const [measuredWidth, setMeasuredWidth] = useState(screenWidth);

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
      captureNewStrokesBase64: (newStrokes, bounds) => {
        try {
          const w = Math.ceil(bounds.width);
          const h = Math.ceil(bounds.height);
          if (w <= 0 || h <= 0) return null;

          const surface = Skia.Surface.Make(w, h);
          if (!surface) return null;

          const canvas = surface.getCanvas();
          canvas.clear(Skia.Color("#FFFFFF"));
          canvas.translate(-bounds.x, -bounds.y);

          for (const stroke of newStrokes) {
            const paint = Skia.Paint();
            paint.setStyle(1); // stroke
            paint.setColor(Skia.Color(stroke.color));
            paint.setStrokeWidth(stroke.width);
            paint.setStrokeCap(1); // round
            paint.setStrokeJoin(1); // round
            canvas.drawPath(stroke.path, paint);
          }

          surface.flush();
          const image = surface.makeImageSnapshot();
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

    // 스케일 팩터: 컨테이너가 줄어들면 콘텐츠를 축소 렌더링하므로,
    // 터치 좌표를 역수로 보정하여 논리 좌표계에 맞춤
    const scale = measuredWidth / screenWidth;
    const invScale = 1 / scale;

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
          runOnJS(onStrokeStart)(e.x * invScale, e.y * invScale);
        }
      })
      .onUpdate((e) => {
        "worklet";
        if (isDrawing.value) {
          runOnJS(onStrokeMove)(e.x * invScale, e.y * invScale);
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
          <View
            ref={viewRef}
            style={styles.canvas}
            collapsable={false}
            onLayout={(e) => setMeasuredWidth(e.nativeEvent.layout.width)}
          >
            <Canvas style={StyleSheet.absoluteFill}>
              <Group transform={[{ scale: measuredWidth / screenWidth }, { translateY: -scrollOffset }]}>
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
