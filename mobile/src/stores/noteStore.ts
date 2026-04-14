import { create } from "zustand";
import {
  NoteRow,
  getAllNotes,
  createNote as dbCreateNote,
  updateNoteTitle as dbUpdateTitle,
  deleteNote as dbDeleteNote,
} from "../services/database";
import logger from "../services/logger";

interface NoteState {
  notes: NoteRow[];
  loading: boolean;
  loadNotes: () => Promise<void>;
  createNote: (title: string, language?: string) => Promise<NoteRow>;
  updateTitle: (id: string, title: string) => Promise<void>;
  deleteNote: (id: string) => Promise<void>;
}

export const useNoteStore = create<NoteState>((set) => ({
  notes: [],
  loading: true,

  loadNotes: async () => {
    set({ loading: true });
    try {
      logger.info("notes", "loadNotes start");
      const notes = await getAllNotes();
      logger.info("notes", "loadNotes done", { count: notes.length });
      set({ notes, loading: false });
    } catch (e: any) {
      logger.error("notes", "loadNotes failed", { error: e?.message ?? String(e) });
      set({ notes: [], loading: false });
    }
  },

  createNote: async (title, language = "en") => {
    try {
      logger.info("notes", "createNote", { title, language });
      const note = await dbCreateNote(title, language);
      set((state) => ({ notes: [note, ...state.notes] }));
      return note;
    } catch (e: any) {
      logger.error("notes", "createNote failed", { error: e?.message ?? String(e) });
      throw e;
    }
  },

  updateTitle: async (id, title) => {
    await dbUpdateTitle(id, title);
    set((state) => ({
      notes: state.notes.map((n) =>
        n.id === id ? { ...n, title, updated_at: new Date().toISOString() } : n
      ),
    }));
  },

  deleteNote: async (id) => {
    await dbDeleteNote(id);
    set((state) => ({ notes: state.notes.filter((n) => n.id !== id) }));
  },
}));
