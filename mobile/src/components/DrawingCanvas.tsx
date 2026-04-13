import React from "react";
import { StyleSheet, View } from "react-native";
import { Canvas, Path, SkPath } from "@shopify/react-native-skia";
import {
  Gesture,
  GestureDetector,
  GestureHandlerRootView,
} from "react-native-gesture-handler";

export interface StrokeData {
  path: SkPath;
  color: string;
  width: number;
}

interface DrawingCanvasProps {
  strokes: StrokeData[];
  currentStroke: StrokeData | null;
  onStrokeStart: (x: number, y: number) => void;
  onStrokeMove: (x: number, y: number) => void;
  onStrokeEnd: () => void;
}

export default function DrawingCanvas({
  strokes,
  currentStroke,
  onStrokeStart,
  onStrokeMove,
  onStrokeEnd,
}: DrawingCanvasProps) {
  const pan = Gesture.Pan()
    .minDistance(0)
    .onBegin((e) => onStrokeStart(e.x, e.y))
    .onUpdate((e) => onStrokeMove(e.x, e.y))
    .onEnd(() => onStrokeEnd())
    .onFinalize(() => onStrokeEnd());

  return (
    <GestureHandlerRootView style={styles.container}>
      <GestureDetector gesture={pan}>
        <View style={styles.canvas}>
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

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff" },
  canvas: { flex: 1 },
});
