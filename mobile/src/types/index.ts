export interface Stroke {
  id: string;
  noteId: string;
  points: { x: number; y: number }[];
  color: string;
  width: number;
  timestamp: string;
}

export interface Feedback {
  id: string;
  noteId: string;
  content: string;
  position: { x: number; y: number };
  boundingBox: { x: number; y: number; width: number; height: number };
  createdAt: string;
}

export interface FeedbackResponse {
  recognized_text: string;
  corrections: {
    position: number;
    original: string;
    corrected: string;
    reason: string;
  }[];
  summary: string;
}

export interface FeedbackRenderItem {
  id: string;
  y: number; // 캔버스 가상 좌표 (스트로크 바운딩 박스 maxY + 24px)
  text: string; // 렌더링할 텍스트
  width: number; // 카드 너비
  height: number; // 카드 높이 (렌더링 후 계산)
}
