import React, { forwardRef, useImperativeHandle, useRef } from "react";
import { StyleSheet, View } from "react-native";
import { Canvas, Path, SkPath, makeImageFromView } from "@shopify/react-native-skia";
import {
  Gesture,
  GestureDetector,
  GestureHandlerRootView,
} from "react-native-gesture-handler";
import { runOnJS } from "react-native-reanimated";

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
  onStrokeStart: (x: number, y: number) => void;
  onStrokeMove: (x: number, y: number) => void;
  onStrokeEnd: () => void;
}

const DrawingCanvas = forwardRef<DrawingCanvasHandle, DrawingCanvasProps>(
  ({ strokes, currentStroke, onStrokeStart, onStrokeMove, onStrokeEnd }, ref) => {
    const viewRef = useRef<View>(null);

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

    const pan = Gesture.Pan()
      .minDistance(0)
      .onBegin((e) => {
        "worklet";
        runOnJS(onStrokeStart)(e.x, e.y);
      })
      .onUpdate((e) => {
        "worklet";
        runOnJS(onStrokeMove)(e.x, e.y);
      })
      .onEnd(() => {
        "worklet";
        runOnJS(onStrokeEnd)();
      })
      .onFinalize(() => {
        "worklet";
        runOnJS(onStrokeEnd)();
      });

    return (
      <GestureHandlerRootView style={styles.container}>
        <GestureDetector gesture={pan}>
          <View ref={viewRef} style={styles.canvas} collapsable={false}>
            <Canvas style={StyleSheet.absoluteFill}>
              {strokes.map((stroke, index) => (
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
