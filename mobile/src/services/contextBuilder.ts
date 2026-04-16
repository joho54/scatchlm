import { getFeedbacksByNoteId } from "./database";

const MAX_CONTEXT_CHARS = 1500;

/**
 * 직전 피드백의 요약을 컨텍스트 텍스트로 반환한다.
 * 최근 1건만 포함 (토큰 절감).
 */
export async function buildPreviousContext(noteId: string): Promise<string | undefined> {
  const rows = await getFeedbacksByNoteId(noteId);
  if (rows.length === 0) return undefined;

  const last = rows[rows.length - 1];
  try {
    const parsed = JSON.parse(last.content);
    const recognized = parsed.recognized_text ?? "";
    const feedback = parsed.feedback ?? "";
    const summary = parsed.summary ?? "";

    let result = `Previous feedback:\nRecognized: "${recognized}"\nFeedback: ${feedback}\nSummary: ${summary}`;

    if (result.length > MAX_CONTEXT_CHARS) {
      result = result.slice(0, MAX_CONTEXT_CHARS - 3) + "...";
    }
    return result;
  } catch {
    return undefined;
  }
}
