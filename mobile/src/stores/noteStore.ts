import { create } from "zustand";

export interface Note {
  id: string;
  title: string;
  language: string;
  createdAt: string;
  updatedAt: string;
}

interface NoteState {
  notes: Note[];
  addNote: (note: Note) => void;
  removeNote: (id: string) => void;
}

export const useNoteStore = create<NoteState>((set) => ({
  notes: [],
  addNote: (note) => set((state) => ({ notes: [...state.notes, note] })),
  removeNote: (id) =>
    set((state) => ({ notes: state.notes.filter((n) => n.id !== id) })),
}));
