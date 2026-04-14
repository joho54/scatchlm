import axios from "axios";
import { requestFeedback } from "../src/services/feedback";

// api 모듈이 supabase를 import하므로 supabase 모킹 필요 (jest.setup.js에서 처리)
jest.mock("axios", () => {
  const instance = {
    post: jest.fn(),
    interceptors: {
      request: { use: jest.fn() },
      response: { use: jest.fn() },
    },
  };
  return {
    create: jest.fn(() => instance),
    __mockInstance: instance,
  };
});

const mockAxios = (axios as any).__mockInstance;

beforeEach(() => {
  jest.clearAllMocks();
});

describe("requestFeedback", () => {
  it("sends FormData with required fields", async () => {
    const mockResponse = {
      data: {
        recognized_text: "hello",
        corrections: [],
        summary: "잘 했습니다.",
      },
    };
    mockAxios.post.mockResolvedValue(mockResponse);

    const imageBase64 = "iVBORw0KGgo=";
    const result = await requestFeedback({
      imageBase64,
      noteId: "note-1",
      language: "ja",
    });

    expect(mockAxios.post).toHaveBeenCalledWith(
      "/feedback",
      expect.any(FormData),
      expect.objectContaining({
        headers: { "Content-Type": "multipart/form-data" },
      })
    );
    expect(result.recognized_text).toBe("hello");
    expect(result.summary).toBe("잘 했습니다.");
  });

  it("includes optional textbook params when provided", async () => {
    mockAxios.post.mockResolvedValue({
      data: { recognized_text: "", corrections: [], summary: "" },
    });

    const imageBase64 = "AQID";
    await requestFeedback({
      imageBase64,
      noteId: "note-1",
      textbookId: "tb-1",
      pageStart: 1,
      pageEnd: 3,
    });

    const formData = mockAxios.post.mock.calls[0][1] as FormData;
    // FormData에 textbook 관련 필드가 포함되어야 함
    expect(formData.get("textbook_id")).toBe("tb-1");
    expect(formData.get("page_start")).toBe("1");
    expect(formData.get("page_end")).toBe("3");
  });

  it("propagates API errors", async () => {
    mockAxios.post.mockRejectedValue(new Error("Network error"));

    await expect(
      requestFeedback({
        imageBase64: "AQ==",
        noteId: "note-1",
      })
    ).rejects.toThrow("Network error");
  });
});
