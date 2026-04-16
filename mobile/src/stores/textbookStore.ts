import { create } from "zustand";
import {
  TextbookListItem,
  fetchTextbooks,
  pickAndUploadPdf,
} from "../services/textbook";
import logger from "../services/logger";

interface TextbookState {
  textbooks: TextbookListItem[];
  loading: boolean;
  loadTextbooks: () => Promise<void>;
  uploadTextbook: () => Promise<TextbookListItem | null>;
}

export const useTextbookStore = create<TextbookState>((set) => ({
  textbooks: [],
  loading: false,

  loadTextbooks: async () => {
    set({ loading: true });
    try {
      const textbooks = await fetchTextbooks();
      logger.info("textbooks", "loaded", { count: textbooks.length });
      set({ textbooks, loading: false });
    } catch (e: any) {
      logger.error("textbooks", "load failed", { error: e?.message });
      set({ loading: false });
    }
  },

  uploadTextbook: async () => {
    try {
      const result = await pickAndUploadPdf();
      if (!result) return null;
      const item: TextbookListItem = {
        id: result.id,
        fileName: result.fileName,
        totalPages: result.totalPages,
        fileSize: result.fileSize,
        createdAt: new Date().toISOString(),
      };
      set((state) => ({ textbooks: [item, ...state.textbooks] }));
      return item;
    } catch (e: any) {
      logger.error("textbooks", "upload failed", { error: e?.message });
      throw e;
    }
  },
}));
