import React, { useCallback, useEffect } from "react";
import { View, StyleSheet, Alert } from "react-native";
import { useLocalSearchParams, useNavigation } from "expo-router";

import DrawingCanvas from "../../src/components/DrawingCanvas";
import Toolbar from "../../src/components/Toolbar";
import { useDrawing } from "../../src/hooks/useDrawing";

export default function NoteScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const navigation = useNavigation();
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

  // 화면 이탈 시 즉시 저장
  useEffect(() => {
    const unsubscribe = navigation.addListener("beforeRemove", () => {
      saveNow();
    });
    return unsubscribe;
  }, [navigation, saveNow]);

  const handleFeedback = useCallback(() => {
    if (strokes.length === 0) {
      Alert.alert("알림", "먼저 캔버스에 내용을 작성해주세요.");
      return;
    }
    // TODO: M3 - 캔버스 캡처 → API 전송 → 피드백 렌더링
    Alert.alert("피드백", "캔버스 캡처 및 API 연동은 다음 마일스톤에서 구현됩니다.");
  }, [strokes]);

  return (
    <View style={styles.container}>
      <DrawingCanvas
        strokes={strokes}
        currentStroke={currentStroke}
        onStrokeStart={onStrokeStart}
        onStrokeMove={onStrokeMove}
        onStrokeEnd={onStrokeEnd}
      />
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
});
