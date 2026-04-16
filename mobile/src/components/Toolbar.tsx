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
  onTogglePdf?: () => void;
  pdfOpen?: boolean;
  hasTextbook?: boolean;
  mode?: "skia" | "pencilkit";
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
  onTogglePdf,
  pdfOpen,
  hasTextbook,
  mode = "skia",
}: ToolbarProps) {
  const isPencilKit = mode === "pencilkit";

  return (
    <View style={styles.container}>
      <View style={styles.row}>
        {/* Skia 전용: 색상/굵기/지우개 (PencilKit에서는 PKToolPicker가 대체) */}
        {!isPencilKit && (
          <>
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
            <View style={styles.divider} />
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
            <TouchableOpacity
              onPress={onEraserToggle}
              style={[styles.toolBtn, isEraser && styles.eraserActive]}
            >
              <Text style={styles.toolText}>지우개</Text>
            </TouchableOpacity>
          </>
        )}

        {/* Undo / Redo (공통) */}
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

      {/* 하단 버튼 행 */}
      <View style={styles.bottomRow}>
        {onTogglePdf && (
          <TouchableOpacity
            onPress={onTogglePdf}
            style={[styles.pdfBtn, pdfOpen && styles.pdfBtnActive]}
          >
            <Text style={[styles.pdfBtnText, pdfOpen && styles.pdfBtnTextActive]}>
              {hasTextbook ? "교재" : "교재 연결"}
            </Text>
          </TouchableOpacity>
        )}
        <TouchableOpacity onPress={onFeedback} style={styles.feedbackBtn}>
          <Text style={styles.feedbackText}>피드백 요청</Text>
        </TouchableOpacity>
      </View>
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
  bottomRow: {
    flexDirection: "row",
    marginTop: 8,
    gap: 8,
  },
  pdfBtn: {
    paddingVertical: 10,
    paddingHorizontal: 16,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: "#ddd",
    backgroundColor: "#fff",
    alignItems: "center",
  },
  pdfBtnActive: {
    borderColor: "#4F46E5",
    backgroundColor: "#EEF2FF",
  },
  pdfBtnText: { fontSize: 14, fontWeight: "600", color: "#666" },
  pdfBtnTextActive: { color: "#4F46E5" },
  feedbackBtn: {
    flex: 1,
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
