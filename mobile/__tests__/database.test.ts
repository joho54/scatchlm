import {
  getDatabase,
  createNote,
  getAllNotes,
  updateNoteTitle,
  deleteNote,
  saveStrokes,
  getStrokesByNoteId,
  saveLastPage,
  savePdfOpen,
} from "../src/services/database";

// expo-sqlite mock에 접근
const sqliteMock = require("expo-sqlite") as any;

beforeEach(() => {
  jest.clearAllMocks();
});

describe("database - notes", () => {
  it("getDatabase initializes DB and creates tables", async () => {
    const db = await getDatabase();
    const mockDb = sqliteMock.__mockDb;
    expect(sqliteMock.openDatabaseAsync).toHaveBeenCalledWith("scatchlm.db");
    // SQL에 CREATE TABLE이 포함되어야 함
    const sql = mockDb.execAsync.mock.calls[0][0];
    expect(sql).toContain("CREATE TABLE IF NOT EXISTS notes");
    expect(sql).toContain("CREATE TABLE IF NOT EXISTS strokes");
    expect(sql).toContain("CREATE TABLE IF NOT EXISTS feedbacks");
  });

  it("createNote inserts a row and returns note data", async () => {
    const note = await createNote("테스트 노트", "ja");
    const db = sqliteMock.__mockDb;
    expect(db.runAsync).toHaveBeenCalledWith(
      expect.stringContaining("INSERT INTO notes"),
      expect.any(String), // id
      "테스트 노트",
      "ja",
      null, // textbook_id
      null, // textbook_name
      0,    // textbook_pages
      expect.any(String), // created_at
      expect.any(String)  // updated_at
    );
    expect(note.title).toBe("테스트 노트");
    expect(note.language).toBe("ja");
    expect(note.id).toMatch(/^[0-9a-f-]+$/);
  });

  it("createNote defaults language to 'en'", async () => {
    const note = await createNote("English note");
    expect(note.language).toBe("en");
  });

  it("getAllNotes calls SELECT ordered by updated_at", async () => {
    await getAllNotes();
    const db = sqliteMock.__mockDb;
    expect(db.getAllAsync).toHaveBeenCalledWith(
      expect.stringContaining("ORDER BY updated_at DESC")
    );
  });

  it("updateNoteTitle calls UPDATE with correct params", async () => {
    await updateNoteTitle("note-123", "새 제목");
    const db = sqliteMock.__mockDb;
    expect(db.runAsync).toHaveBeenCalledWith(
      expect.stringContaining("UPDATE notes SET title"),
      "새 제목",
      expect.any(String), // updated_at
      "note-123"
    );
  });

  it("deleteNote calls DELETE with correct id", async () => {
    await deleteNote("note-456");
    const db = sqliteMock.__mockDb;
    expect(db.runAsync).toHaveBeenCalledWith(
      "DELETE FROM notes WHERE id = ?",
      "note-456"
    );
  });
});

describe("database - PDF state", () => {
  it("saveLastPage updates last_page for valid page", async () => {
    await saveLastPage("note-123", 42);
    const db = sqliteMock.__mockDb;
    expect(db.runAsync).toHaveBeenCalledWith(
      "UPDATE notes SET last_page = ? WHERE id = ?",
      42,
      "note-123"
    );
  });

  it("saveLastPage ignores invalid page values", async () => {
    const db = sqliteMock.__mockDb;
    db.runAsync.mockClear();

    await saveLastPage("note-123", -1);
    await saveLastPage("note-123", 0);
    await saveLastPage("note-123", Infinity);
    await saveLastPage("note-123", 99999);

    expect(db.runAsync).not.toHaveBeenCalled();
  });

  it("savePdfOpen saves open state as 1", async () => {
    await savePdfOpen("note-123", true);
    const db = sqliteMock.__mockDb;
    expect(db.runAsync).toHaveBeenCalledWith(
      "UPDATE notes SET pdf_open = ? WHERE id = ?",
      1,
      "note-123"
    );
  });

  it("savePdfOpen saves closed state as 0", async () => {
    await savePdfOpen("note-456", false);
    const db = sqliteMock.__mockDb;
    expect(db.runAsync).toHaveBeenCalledWith(
      "UPDATE notes SET pdf_open = ? WHERE id = ?",
      0,
      "note-456"
    );
  });
});

describe("database - strokes", () => {
  it("saveStrokes deletes existing and inserts new strokes", async () => {
    const strokes = [
      { svgPath: "M0,0 L10,10", color: "#000", width: 4 },
      { svgPath: "M5,5 L20,20", color: "#FF0000", width: 2 },
    ];
    await saveStrokes("note-abc", strokes);
    const db = sqliteMock.__mockDb;

    // 기존 삭제 호출
    expect(db.runAsync).toHaveBeenCalledWith(
      "DELETE FROM strokes WHERE note_id = ?",
      "note-abc"
    );

    // INSERT 2회 (스트로크 2개)
    const insertCalls = db.runAsync.mock.calls.filter(
      (c: string[]) => typeof c[0] === "string" && c[0].includes("INSERT INTO strokes")
    );
    expect(insertCalls.length).toBe(2);

    // updated_at 갱신
    expect(db.runAsync).toHaveBeenCalledWith(
      "UPDATE notes SET updated_at = ? WHERE id = ?",
      expect.any(String),
      "note-abc"
    );
  });

  it("getStrokesByNoteId queries with correct noteId", async () => {
    await getStrokesByNoteId("note-xyz");
    const db = sqliteMock.__mockDb;
    expect(db.getAllAsync).toHaveBeenCalledWith(
      expect.stringContaining("WHERE note_id = ?"),
      "note-xyz"
    );
  });
});
