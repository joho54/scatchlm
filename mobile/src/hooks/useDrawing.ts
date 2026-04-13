import { useCallback, useEffect, useRef, useState } from "react";
import { Skia } from "@shopify/react-native-skia";
import type { StrokeData } from "../components/DrawingCanvas";
import { getStrokesByNoteId, saveStrokes } from "../services/database";

const ERASER_COLOR = "#FFFFFF";
const ERASER_WIDTH = 20;
const AUTO_SAVE_DELAY = 2000;

export function useDrawing(noteId?: string) {
  const [strokes, setStrokes] = useState<StrokeData[]>([]);
  const [currentStroke, setCurrentStroke] = useState<StrokeData | null>(null);
  const [penColor, setPenColor] = useState("#000000");
  const [penWidth, setPenWidth] = useState(4);
  const [isEraser, setIsEraser] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const redoStack = useRef<StrokeData[]>([]);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // 스트로크 로드
  useEffect(() => {
    if (!noteId) return;
    (async () => {
      const rows = await getStrokesByNoteId(noteId);
      const restored: StrokeData[] = [];
      for (const row of rows) {
        const path = Skia.Path.MakeFromSVGString(row.svg_path);
        if (path) {
          restored.push({ path, color: row.color, width: row.width });
        }
      }
      setStrokes(restored);
      setLoaded(true);
    })();
  }, [noteId]);

  // 자동 저장
  const scheduleSave = useCallback(
    (updatedStrokes: StrokeData[]) => {
      if (!noteId || !loaded) return;
      if (saveTimer.current) clearTimeout(saveTimer.current);
      saveTimer.current = setTimeout(() => {
        const data = updatedStrokes.map((s) => ({
          svgPath: s.path.toSVGString(),
          color: s.color,
          width: s.width,
        }));
        saveStrokes(noteId, data);
      }, AUTO_SAVE_DELAY);
    },
    [noteId, loaded]
  );

  const onStrokeStart = useCallback(
    (x: number, y: number) => {
      const path = Skia.Path.Make();
      path.moveTo(x, y);
      setCurrentStroke({
        path,
        color: isEraser ? ERASER_COLOR : penColor,
        width: isEraser ? ERASER_WIDTH : penWidth,
      });
      redoStack.current = [];
    },
    [penColor, penWidth, isEraser]
  );

  const onStrokeMove = useCallback((x: number, y: number) => {
    setCurrentStroke((prev) => {
      if (!prev) return null;
      prev.path.lineTo(x, y);
      return { ...prev };
    });
  }, []);

  const onStrokeEnd = useCallback(() => {
    setCurrentStroke((prev) => {
      if (prev) {
        setStrokes((s) => {
          const updated = [...s, prev];
          scheduleSave(updated);
          return updated;
        });
      }
      return null;
    });
  }, [scheduleSave]);

  const undo = useCallback(() => {
    setStrokes((prev) => {
      if (prev.length === 0) return prev;
      const last = prev[prev.length - 1];
      redoStack.current.push(last);
      const updated = prev.slice(0, -1);
      scheduleSave(updated);
      return updated;
    });
  }, [scheduleSave]);

  const redo = useCallback(() => {
    const stroke = redoStack.current.pop();
    if (stroke) {
      setStrokes((prev) => {
        const updated = [...prev, stroke];
        scheduleSave(updated);
        return updated;
      });
    }
  }, [scheduleSave]);

  const toggleEraser = useCallback(() => {
    setIsEraser((prev) => !prev);
  }, []);

  // 즉시 저장 (화면 나갈 때 호출용)
  const saveNow = useCallback(async () => {
    if (!noteId) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    const data = strokes.map((s) => ({
      svgPath: s.path.toSVGString(),
      color: s.color,
      width: s.width,
    }));
    await saveStrokes(noteId, data);
  }, [noteId, strokes]);

  return {
    strokes,
    currentStroke,
    penColor,
    penWidth,
    isEraser,
    loaded,
    canUndo: strokes.length > 0,
    canRedo: redoStack.current.length > 0,
    setPenColor,
    setPenWidth,
    toggleEraser,
    onStrokeStart,
    onStrokeMove,
    onStrokeEnd,
    undo,
    redo,
    saveNow,
  };
}
