import React, { useRef, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  Alert,
  Platform,
  Image,
} from "react-native";
import { useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";

// expo-pencilkit-ui — iOS only
let PencilKitViewComponent: any = null;
if (Platform.OS === "ios") {
  try {
    const mod = require("expo-pencilkit-ui");
    PencilKitViewComponent = mod.PencilKitView ?? mod.default;
  } catch {
    // Library not available
  }
}

/**
 * PencilKit POC 화면
 *
 * 검증 항목:
 * 1. PencilKitView 마운트 + 필기 입력
 * 2. PNG 캡처 (base64)
 * 3. 스크롤 동작 (네이티브 UIScrollView)
 * 4. undo/redo
 * 5. 도구 전환 (pen/eraser)
 * 6. PKDrawing 저장/로드 (base64 blob)
 */
export default function PocPencilKit() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const pencilKitRef = useRef<any>(null);
  const [capturedImage, setCapturedImage] = useState<string | null>(null);
  const [savedDrawing, setSavedDrawing] = useState<string | null>(null);
  const [log, setLog] = useState<string[]>([]);

  const addLog = (msg: string) => {
    const time = new Date().toLocaleTimeString("ko-KR", { hour12: false });
    setLog((prev) => [`[${time}] ${msg}`, ...prev].slice(0, 20));
  };

  if (Platform.OS !== "ios" || !PencilKitViewComponent) {
    return (
      <View style={[styles.container, { paddingTop: insets.top }]}>
        <Text style={styles.errorText}>
          PencilKit is iOS only. Run on iPad device.
        </Text>
        <TouchableOpacity onPress={() => router.back()}>
          <Text style={styles.link}>Back</Text>
        </TouchableOpacity>
      </View>
    );
  }

  const handleCapture = async () => {
    try {
      const base64 = await pencilKitRef.current?.captureDrawing();
      if (base64) {
        setCapturedImage(base64);
        addLog(`Captured PNG: ${(base64.length / 1024).toFixed(1)}KB base64`);
      } else {
        addLog("Capture returned null");
      }
    } catch (e: any) {
      addLog(`Capture error: ${e.message}`);
    }
  };

  const handleSaveDrawing = async () => {
    try {
      const data = await pencilKitRef.current?.getCanvasDataAsBase64();
      if (data) {
        setSavedDrawing(data);
        addLog(`Saved PKDrawing: ${(data.length / 1024).toFixed(1)}KB`);
      } else {
        addLog("Save returned null");
      }
    } catch (e: any) {
      addLog(`Save error: ${e.message}`);
    }
  };

  const handleLoadDrawing = async () => {
    if (!savedDrawing) {
      addLog("No saved drawing to load");
      return;
    }
    try {
      await pencilKitRef.current?.setCanvasDataFromBase64(savedDrawing);
      addLog("Loaded PKDrawing from saved data");
    } catch (e: any) {
      addLog(`Load error: ${e.message}`);
    }
  };

  const handleClear = async () => {
    try {
      await pencilKitRef.current?.clearDrawing();
      setCapturedImage(null);
      addLog("Canvas cleared");
    } catch (e: any) {
      addLog(`Clear error: ${e.message}`);
    }
  };

  const handleUndo = async () => {
    try {
      await pencilKitRef.current?.undo();
      addLog("Undo");
    } catch (e: any) {
      addLog(`Undo error: ${e.message}`);
    }
  };

  const handleRedo = async () => {
    try {
      await pencilKitRef.current?.redo();
      addLog("Redo");
    } catch (e: any) {
      addLog(`Redo error: ${e.message}`);
    }
  };

  const handleSetupToolPicker = async () => {
    try {
      await pencilKitRef.current?.setupToolPicker();
      addLog("Tool picker shown");
    } catch (e: any) {
      addLog(`ToolPicker error: ${e.message}`);
    }
  };

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <TouchableOpacity onPress={() => router.back()}>
          <Text style={styles.link}>← Back</Text>
        </TouchableOpacity>
        <Text style={styles.title}>PencilKit POC</Text>
        <View style={{ width: 60 }} />
      </View>

      {/* PencilKit Canvas */}
      <View style={styles.canvasContainer}>
        <PencilKitViewComponent
          ref={pencilKitRef}
          style={styles.pencilKit}
          onDrawStart={() => addLog("Draw start")}
          onDrawEnd={() => addLog("Draw end")}
          onCanUndoChanged={(e: any) => addLog(`canUndo: ${e.nativeEvent.canUndo}`)}
          onCanRedoChanged={(e: any) => addLog(`canRedo: ${e.nativeEvent.canRedo}`)}
        />
      </View>

      {/* Captured image preview */}
      {capturedImage && (
        <View style={styles.preview}>
          <Text style={styles.previewLabel}>Captured PNG:</Text>
          <Image
            source={{ uri: `data:image/png;base64,${capturedImage}` }}
            style={styles.previewImage}
            resizeMode="contain"
          />
        </View>
      )}

      {/* Controls */}
      <View style={styles.controls}>
        <TouchableOpacity style={styles.btn} onPress={handleSetupToolPicker}>
          <Text style={styles.btnText}>Tools</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.btn} onPress={handleUndo}>
          <Text style={styles.btnText}>Undo</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.btn} onPress={handleRedo}>
          <Text style={styles.btnText}>Redo</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.btn} onPress={handleClear}>
          <Text style={styles.btnText}>Clear</Text>
        </TouchableOpacity>
        <TouchableOpacity style={[styles.btn, styles.btnPrimary]} onPress={handleCapture}>
          <Text style={[styles.btnText, styles.btnPrimaryText]}>Capture</Text>
        </TouchableOpacity>
      </View>
      <View style={styles.controls}>
        <TouchableOpacity style={styles.btn} onPress={handleSaveDrawing}>
          <Text style={styles.btnText}>Save Data</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.btn, !savedDrawing && styles.btnDisabled]}
          onPress={handleLoadDrawing}
        >
          <Text style={styles.btnText}>Load Data</Text>
        </TouchableOpacity>
      </View>

      {/* Log */}
      <View style={styles.logContainer}>
        {log.map((entry, i) => (
          <Text key={i} style={styles.logText}>{entry}</Text>
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#f5f5f5" },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: "#fff",
    borderBottomWidth: 1,
    borderBottomColor: "#e0e0e0",
  },
  title: { fontSize: 17, fontWeight: "600" },
  link: { fontSize: 16, color: "#007AFF" },
  errorText: { fontSize: 16, textAlign: "center", marginTop: 100, color: "#666" },
  canvasContainer: {
    flex: 1,
    margin: 8,
    borderRadius: 12,
    overflow: "hidden",
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#ddd",
  },
  pencilKit: { flex: 1 },
  preview: {
    height: 100,
    marginHorizontal: 8,
    marginBottom: 4,
    backgroundColor: "#fff",
    borderRadius: 8,
    padding: 8,
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  previewLabel: { fontSize: 12, color: "#666" },
  previewImage: { flex: 1, height: 80 },
  controls: {
    flexDirection: "row",
    paddingHorizontal: 8,
    paddingVertical: 4,
    gap: 6,
    flexWrap: "wrap",
  },
  btn: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    backgroundColor: "#fff",
    borderRadius: 8,
    borderWidth: 1,
    borderColor: "#ddd",
  },
  btnPrimary: { backgroundColor: "#007AFF", borderColor: "#007AFF" },
  btnPrimaryText: { color: "#fff" },
  btnDisabled: { opacity: 0.4 },
  btnText: { fontSize: 14, fontWeight: "500" },
  logContainer: {
    height: 120,
    marginHorizontal: 8,
    marginBottom: 8,
    padding: 8,
    backgroundColor: "#1a1a2e",
    borderRadius: 8,
  },
  logText: { fontSize: 11, color: "#8be9fd", fontFamily: "Courier", lineHeight: 16 },
});
