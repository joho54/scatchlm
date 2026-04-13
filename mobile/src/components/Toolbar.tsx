import React from "react";
import { View, TouchableOpacity, Text, StyleSheet } from "react-native";

const COLORS = ["#000000", "#FF0000", "#0066FF", "#00AA00", "#FF6600"];
const WIDTHS = [2, 4, 8];

interface ToolbarProps {
  penColor: string;
  penWidth: number;
  isEraser: boolean;
  canUndo: boolean;
  canRedo: boolean;
  onColorChange: (color: string) => void;
  onWidthChange: (width: number) => void;
  onEraserToggle: () => void;
  onUndo: () => void;
  onRedo: () => void;
  onFeedback: () => void;
}

export default function Toolbar({
  penColor,
  penWidth,
  isEraser,
  canUndo,
  canRedo,
  onColorChange,
  onWidthChange,
  onEraserToggle,
  onUndo,
  onRedo,
  onFeedback,
}: ToolbarProps) {
  return (
    <View style={styles.container}>
      <View style={styles.row}>
        {/* 색상 선택 */}
        {COLORS.map((color) => (
          <TouchableOpacity
            key={color}
            onPress={() => onColorChange(color)}
            style={[
              styles.colorBtn,
              { backgroundColor: color },
              penColor === color && !isEraser && styles.selected,
            ]}
          />
        ))}

        {/* 구분선 */}
        <View style={styles.divider} />

        {/* 펜 굵기 */}
        {WIDTHS.map((w) => (
          <TouchableOpacity
            key={w}
            onPress={() => onWidthChange(w)}
            style={[styles.widthBtn, penWidth === w && !isEraser && styles.selected]}
          >
            <View
              style={{
                width: w * 3,
                height: w * 3,
                borderRadius: w * 1.5,
                backgroundColor: "#333",
              }}
            />
          </TouchableOpacity>
        ))}

        <View style={styles.divider} />

        {/* 지우개 */}
        <TouchableOpacity
          onPress={onEraserToggle}
          style={[styles.toolBtn, isEraser && styles.eraserActive]}
        >
          <Text style={styles.toolText}>지우개</Text>
        </TouchableOpacity>

        {/* Undo / Redo */}
        <TouchableOpacity
          onPress={onUndo}
          disabled={!canUndo}
          style={[styles.toolBtn, !canUndo && styles.disabled]}
        >
          <Text style={styles.toolText}>↩</Text>
        </TouchableOpacity>
        <TouchableOpacity
          onPress={onRedo}
          disabled={!canRedo}
          style={[styles.toolBtn, !canRedo && styles.disabled]}
        >
          <Text style={styles.toolText}>↪</Text>
        </TouchableOpacity>
      </View>

      {/* 피드백 버튼 */}
      <TouchableOpacity onPress={onFeedback} style={styles.feedbackBtn}>
        <Text style={styles.feedbackText}>피드백 요청</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: "#f8f8f8",
    borderTopWidth: 1,
    borderTopColor: "#ddd",
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  colorBtn: {
    width: 28,
    height: 28,
    borderRadius: 14,
    borderWidth: 2,
    borderColor: "transparent",
  },
  selected: {
    borderColor: "#007AFF",
    borderWidth: 2,
  },
  divider: {
    width: 1,
    height: 24,
    backgroundColor: "#ccc",
    marginHorizontal: 4,
  },
  widthBtn: {
    width: 32,
    height: 32,
    borderRadius: 16,
    justifyContent: "center",
    alignItems: "center",
    borderWidth: 2,
    borderColor: "transparent",
  },
  toolBtn: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 6,
    backgroundColor: "#eee",
  },
  toolText: {
    fontSize: 14,
    fontWeight: "600",
  },
  eraserActive: {
    backgroundColor: "#FFD700",
  },
  disabled: {
    opacity: 0.3,
  },
  feedbackBtn: {
    marginTop: 8,
    backgroundColor: "#007AFF",
    paddingVertical: 10,
    borderRadius: 8,
    alignItems: "center",
  },
  feedbackText: {
    color: "#fff",
    fontSize: 16,
    fontWeight: "bold",
  },
});
