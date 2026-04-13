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
