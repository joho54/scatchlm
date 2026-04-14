import api from "./api";
import type { FeedbackResponse } from "../types";

export async function requestFeedback(params: {
  imageBase64: string;
  noteId: string;
  language?: string;
  taskType?: string;
  textbookId?: string;
  pageStart?: number;
  pageEnd?: number;
  previousContext?: string;
}): Promise<FeedbackResponse> {
  // RN에서는 base64 data URI를 FormData에 직접 첨부
  const formData = new FormData();
  formData.append("image", {
    uri: `data:image/png;base64,${params.imageBase64}`,
    name: "canvas.png",
    type: "image/png",
  } as any);
  formData.append("note_id", params.noteId);
  formData.append("language", params.language ?? "en");
  formData.append("task_type", params.taskType ?? "complex");

  if (params.textbookId) {
    formData.append("textbook_id", params.textbookId);
  }
  if (params.pageStart !== undefined) {
    formData.append("page_start", String(params.pageStart));
  }
  if (params.pageEnd !== undefined) {
    formData.append("page_end", String(params.pageEnd));
  }
  if (params.previousContext) {
    formData.append("previous_context", params.previousContext);
  }

  const res = await api.post<FeedbackResponse>("/feedback", formData, {
    headers: { "Content-Type": "multipart/form-data" },
  });
  return res.data;
}
