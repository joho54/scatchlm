import * as DocumentPicker from "expo-document-picker";
import api from "./api";
import logger from "./logger";

export interface TextbookUploadResult {
  id: string;
  fileName: string;
  totalPages: number;
  fileSize: number;
  indexing: string;
}

export async function pickAndUploadPdf(noteId: string): Promise<TextbookUploadResult | null> {
  // 파일 선택
  const result = await DocumentPicker.getDocumentAsync({
    type: "application/pdf",
    copyToCacheDirectory: true,
  });

  if (result.canceled || !result.assets?.[0]) {
    logger.info("textbook", "PDF picker cancelled");
    return null;
  }

  const file = result.assets[0];
  logger.info("textbook", "PDF selected", { name: file.name, size: file.size });

  // 업로드
  const formData = new FormData();
  formData.append("file", {
    uri: file.uri,
    name: file.name,
    type: "application/pdf",
  } as any);
  formData.append("note_id", noteId);

  const res = await api.post<TextbookUploadResult>("/pdf/upload", formData, {
    headers: { "Content-Type": "multipart/form-data" },
  });

  logger.info("textbook", "upload done", {
    id: res.data.id,
    pages: res.data.totalPages,
    indexing: res.data.indexing,
  });

  return res.data;
}
