import * as SQLite from "expo-sqlite";
import uuid from "../utils/uuid";

let db: SQLite.SQLiteDatabase | null = null;

export async function getDatabase(): Promise<SQLite.SQLiteDatabase> {
  if (db) return db;
  db = await SQLite.openDatabaseAsync("scatchlm.db");
  await db.execAsync(`
    CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      language TEXT NOT NULL DEFAULT 'en',
      textbook_id TEXT,
      textbook_name TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS strokes (
      id TEXT PRIMARY KEY,
      note_id TEXT NOT NULL,
      svg_path TEXT NOT NULL,
      color TEXT NOT NULL,
      width REAL NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (note_id) REFERENCES notes(id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS feedbacks (
      id TEXT PRIMARY KEY,
      note_id TEXT NOT NULL,
      content TEXT NOT NULL,
      position_x REAL NOT NULL,
      position_y REAL NOT NULL,
      bbox_x REAL NOT NULL,
      bbox_y REAL NOT NULL,
      bbox_width REAL NOT NULL,
      bbox_height REAL NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (note_id) REFERENCES notes(id) ON DELETE CASCADE
    );
  `);

  // 마이그레이션: 기존 notes 테이블에 textbook 컬럼 추가
  try {
    await db.execAsync(`ALTER TABLE notes ADD COLUMN textbook_id TEXT;`);
  } catch {}
  try {
    await db.execAsync(`ALTER TABLE notes ADD COLUMN textbook_name TEXT;`);
  } catch {}

  return db;
}

// ── Notes ──

export interface NoteRow {
  id: string;
  title: string;
  language: string;
  textbook_id: string | null;
  textbook_name: string | null;
  created_at: string;
  updated_at: string;
}

export async function getAllNotes(): Promise<NoteRow[]> {
  const db = await getDatabase();
  return db.getAllAsync<NoteRow>(
    "SELECT * FROM notes ORDER BY updated_at DESC"
  );
}

export async function createNote(
  title: string,
  language: string = "en"
): Promise<NoteRow> {
  const db = await getDatabase();
  const id = uuid();
  const now = new Date().toISOString();
  await db.runAsync(
    "INSERT INTO notes (id, title, language, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
    id,
    title,
    language,
    now,
    now
  );
  return { id, title, language, textbook_id: null, textbook_name: null, created_at: now, updated_at: now };
}

export async function updateNoteTitle(
  id: string,
  title: string
): Promise<void> {
  const db = await getDatabase();
  const now = new Date().toISOString();
  await db.runAsync(
    "UPDATE notes SET title = ?, updated_at = ? WHERE id = ?",
    title,
    now,
    id
  );
}

export async function deleteNote(id: string): Promise<void> {
  const db = await getDatabase();
  await db.runAsync("DELETE FROM notes WHERE id = ?", id);
}

export async function linkTextbook(
  noteId: string,
  textbookId: string,
  textbookName: string
): Promise<void> {
  const db = await getDatabase();
  const now = new Date().toISOString();
  await db.runAsync(
    "UPDATE notes SET textbook_id = ?, textbook_name = ?, updated_at = ? WHERE id = ?",
    textbookId,
    textbookName,
    now,
    noteId
  );
}

export async function unlinkTextbook(noteId: string): Promise<void> {
  const db = await getDatabase();
  const now = new Date().toISOString();
  await db.runAsync(
    "UPDATE notes SET textbook_id = NULL, textbook_name = NULL, updated_at = ? WHERE id = ?",
    now,
    noteId
  );
}

export async function getNoteById(noteId: string): Promise<NoteRow | null> {
  const db = await getDatabase();
  const rows = await db.getAllAsync<NoteRow>(
    "SELECT * FROM notes WHERE id = ?",
    noteId
  );
  return rows[0] ?? null;
}

// ── Strokes ──

export interface StrokeRow {
  id: string;
  note_id: string;
  svg_path: string;
  color: string;
  width: number;
  created_at: string;
}

export async function getStrokesByNoteId(
  noteId: string
): Promise<StrokeRow[]> {
  const db = await getDatabase();
  return db.getAllAsync<StrokeRow>(
    "SELECT * FROM strokes WHERE note_id = ? ORDER BY created_at ASC",
    noteId
  );
}

export async function saveStrokes(
  noteId: string,
  strokes: { svgPath: string; color: string; width: number }[]
): Promise<void> {
  const db = await getDatabase();
  const now = new Date().toISOString();

  // 기존 스트로크 삭제 후 새로 저장 (전체 교체 방식)
  await db.runAsync("DELETE FROM strokes WHERE note_id = ?", noteId);

  for (const stroke of strokes) {
    await db.runAsync(
      "INSERT INTO strokes (id, note_id, svg_path, color, width, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      uuid(),
      noteId,
      stroke.svgPath,
      stroke.color,
      stroke.width,
      now
    );
  }

  // 노트 updated_at 갱신
  await db.runAsync(
    "UPDATE notes SET updated_at = ? WHERE id = ?",
    now,
    noteId
  );
}

// ── Feedbacks ──

export interface FeedbackRow {
  id: string;
  note_id: string;
  content: string;
  position_x: number;
  position_y: number;
  bbox_x: number;
  bbox_y: number;
  bbox_width: number;
  bbox_height: number;
  created_at: string;
}

export async function getFeedbacksByNoteId(
  noteId: string
): Promise<FeedbackRow[]> {
  const db = await getDatabase();
  return db.getAllAsync<FeedbackRow>(
    "SELECT * FROM feedbacks WHERE note_id = ? ORDER BY created_at ASC",
    noteId
  );
}

export async function saveFeedback(
  noteId: string,
  content: string,
  position: { x: number; y: number },
  boundingBox: { x: number; y: number; width: number; height: number }
): Promise<FeedbackRow> {
  const db = await getDatabase();
  const id = uuid();
  const now = new Date().toISOString();
  await db.runAsync(
    `INSERT INTO feedbacks (id, note_id, content, position_x, position_y,
     bbox_x, bbox_y, bbox_width, bbox_height, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    id,
    noteId,
    content,
    position.x,
    position.y,
    boundingBox.x,
    boundingBox.y,
    boundingBox.width,
    boundingBox.height,
    now
  );
  return {
    id,
    note_id: noteId,
    content,
    position_x: position.x,
    position_y: position.y,
    bbox_x: boundingBox.x,
    bbox_y: boundingBox.y,
    bbox_width: boundingBox.width,
    bbox_height: boundingBox.height,
    created_at: now,
  };
}
