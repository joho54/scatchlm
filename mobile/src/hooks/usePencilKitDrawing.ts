import { useCallback, useEffect, useRef, useState } from "react";
import { saveDrawingData, getDrawingData } from "../services/database";
import logger from "../services/logger";

const AUTO_SAVE_DELAY = 2000;

export function usePencilKitDrawing(noteId?: string) {
  const pencilKitRef = useRef<any>(null);
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);
  const scrollOffsetRef = useRef(0);
  const [strokeCount, setStrokeCount] = useState(0);
  const [loaded, setLoaded] = useState(false);
  const lastFeedbackStrokeCount = useRef(0);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // PKDrawing 로드
  useEffect(() => {
    if (!noteId) return;
    (async () => {
      const data = await getDrawingData(noteId);
      if (data && pencilKitRef.current) {
        await pencilKitRef.current.setCanvasDataFromBase64(data);
        const count = await pencilKitRef.current.getStrokeCount();
        setStrokeCount(count);
        lastFeedbackStrokeCount.current = count;
        logger.info("pencilkit", "drawing loaded", { noteId, dataSize: data.length });
      }
      setLoaded(true);
    })();
  }, [noteId]);

  // 자동 저장 (디바운스)
  const scheduleSave = useCallback(() => {
    if (!noteId || !loaded) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(async () => {
      try {
        const data = await pencilKitRef.current?.getCanvasDataAsBase64();
        if (data) {
          await saveDrawingData(noteId, data);
        }
      } catch (e: any) {
        logger.error("pencilkit", "auto-save failed", { error: e?.message });
      }
    }, AUTO_SAVE_DELAY);
  }, [noteId, loaded]);

  // 즉시 저장 (화면 나갈 때)
  const saveNow = useCallback(async () => {
    if (!noteId) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    try {
      const data = await pencilKitRef.current?.getCanvasDataAsBase64();
      if (data) {
        await saveDrawingData(noteId, data);
        logger.info("pencilkit", "saved", { noteId });
      }
    } catch (e: any) {
      logger.error("pencilkit", "save failed", { error: e?.message });
    }
  }, [noteId]);

  // 네이티브 이벤트 핸들러
  const onDrawEnd = useCallback(() => {
    scheduleSave();
  }, [scheduleSave]);

  const onCanUndoChanged = useCallback((e: any) => {
    setCanUndo(e.nativeEvent.canUndo);
  }, []);

  const onCanRedoChanged = useCallback((e: any) => {
    setCanRedo(e.nativeEvent.canRedo);
  }, []);

  const onScroll = useCallback((e: any) => {
    scrollOffsetRef.current = e.nativeEvent.contentOffsetY;
  }, []);

  const onStrokeCountChanged = useCallback((e: any) => {
    setStrokeCount(e.nativeEvent.strokeCount);
  }, []);

  // 네이티브 액션 위임
  const undo = useCallback(() => {
    pencilKitRef.current?.undo();
  }, []);

  const redo = useCallback(() => {
    pencilKitRef.current?.redo();
  }, []);

  const setupToolPicker = useCallback(() => {
    pencilKitRef.current?.setupToolPicker();
  }, []);

  // 캡처
  const captureFullBase64 = useCallback(async (): Promise<string | null> => {
    try {
      const base64 = await pencilKitRef.current?.captureDrawing();
      return base64 || null;
    } catch {
      return null;
    }
  }, []);

  const captureRegionBase64 = useCallback(
    async (rect: { x: number; y: number; width: number; height: number }): Promise<string | null> => {
      try {
        const base64 = await pencilKitRef.current?.captureRegion(
          rect.x, rect.y, rect.width, rect.height
        );
        return base64 || null;
      } catch {
        return null;
      }
    },
    []
  );

  // 드로잉 바운딩 박스 조회
  const getDrawingBounds = useCallback(async (): Promise<{ x: number; y: number; width: number; height: number }> => {
    try {
      return await pencilKitRef.current?.getDrawingBounds() ?? { x: 0, y: 0, width: 0, height: 0 };
    } catch {
      return { x: 0, y: 0, width: 0, height: 0 };
    }
  }, []);

  // 피드백 추적
  const hasNewStrokes = strokeCount > lastFeedbackStrokeCount.current;

  const markFeedbackPoint = useCallback(() => {
    lastFeedbackStrokeCount.current = strokeCount;
  }, [strokeCount]);

  return {
    pencilKitRef,
    canUndo,
    canRedo,
    get scrollOffset() { return scrollOffsetRef.current; },
    strokeCount,
    hasNewStrokes,
    loaded,
    undo,
    redo,
    setupToolPicker,
    saveNow,
    captureFullBase64,
    captureRegionBase64,
    getDrawingBounds,
    markFeedbackPoint,
    // PencilKitView에 전달할 이벤트 핸들러
    onDrawEnd,
    onCanUndoChanged,
    onCanRedoChanged,
    onScroll,
    onStrokeCountChanged,
  };
}
