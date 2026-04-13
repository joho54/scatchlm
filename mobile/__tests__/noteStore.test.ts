import { useNoteStore } from "../src/stores/noteStore";
import * as db from "../src/services/database";

jest.mock("../src/services/database");

const mockDb = db as jest.Mocked<typeof db>;

beforeEach(() => {
  jest.clearAllMocks();
  // store 초기화
  useNoteStore.setState({ notes: [], loading: true });
});

describe("noteStore", () => {
  it("loadNotes fetches from DB and sets state", async () => {
    const mockNotes = [
      {
        id: "1",
        title: "노트1",
        language: "en",
        created_at: "2026-01-01",
        updated_at: "2026-01-01",
      },
    ];
    mockDb.getAllNotes.mockResolvedValue(mockNotes);

    await useNoteStore.getState().loadNotes();

    expect(mockDb.getAllNotes).toHaveBeenCalled();
    expect(useNoteStore.getState().notes).toEqual(mockNotes);
    expect(useNoteStore.getState().loading).toBe(false);
  });

  it("createNote adds to DB and prepends to state", async () => {
    const newNote = {
      id: "new-1",
      title: "새 노트",
      language: "ja",
      created_at: "2026-01-02",
      updated_at: "2026-01-02",
    };
    mockDb.createNote.mockResolvedValue(newNote);

    const result = await useNoteStore.getState().createNote("새 노트", "ja");

    expect(mockDb.createNote).toHaveBeenCalledWith("새 노트", "ja");
    expect(result).toEqual(newNote);
    expect(useNoteStore.getState().notes[0]).toEqual(newNote);
  });

  it("updateTitle updates DB and state", async () => {
    useNoteStore.setState({
      notes: [
        {
          id: "1",
          title: "원래 제목",
          language: "en",
          created_at: "2026-01-01",
          updated_at: "2026-01-01",
        },
      ],
    });
    mockDb.updateNoteTitle.mockResolvedValue();

    await useNoteStore.getState().updateTitle("1", "바뀐 제목");

    expect(mockDb.updateNoteTitle).toHaveBeenCalledWith("1", "바뀐 제목");
    expect(useNoteStore.getState().notes[0].title).toBe("바뀐 제목");
  });

  it("deleteNote removes from DB and state", async () => {
    useNoteStore.setState({
      notes: [
        {
          id: "1",
          title: "삭제할 노트",
          language: "en",
          created_at: "2026-01-01",
          updated_at: "2026-01-01",
        },
        {
          id: "2",
          title: "남는 노트",
          language: "en",
          created_at: "2026-01-01",
          updated_at: "2026-01-01",
        },
      ],
    });
    mockDb.deleteNote.mockResolvedValue();

    await useNoteStore.getState().deleteNote("1");

    expect(mockDb.deleteNote).toHaveBeenCalledWith("1");
    expect(useNoteStore.getState().notes).toHaveLength(1);
    expect(useNoteStore.getState().notes[0].id).toBe("2");
  });
});
