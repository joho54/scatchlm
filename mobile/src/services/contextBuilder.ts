import { getFeedbacksByNoteId, FeedbackRow } from "./database";
import type { FeedbackResponse } from "../types";

const MAX_HISTORY_ITEMS = 5;
const MAX_CONTEXT_CHARS = 1500;

interface HistoryEntry {
  recognized_text: string;
  errors: string[];
  summary: string;
}

/**
 * 노트의 이전 피드백 히스토리를 구조화된 텍스트로 조합한다.
 * 최근 MAX_HISTORY_ITEMS개의 피드백만 포함하며, MAX_CONTEXT_CHARS를 초과하지 않는다.
 */
export async function buildPreviousContext(noteId: string): Promise<string | undefined> {
  const rows = await getFeedbacksByNoteId(noteId);
  if (rows.length === 0) return undefined;

  const recent = rows.slice(-MAX_HISTORY_ITEMS);
  const history: HistoryEntry[] = [];

  for (const row of recent) {
    try {
      const fb: FeedbackResponse = JSON.parse(row.content);
      history.push({
        recognized_text: fb.recognized_text,
        errors: fb.corrections.map(
          (c) => `${c.original}→${c.corrected}(${c.reason})`
        ),
        summary: fb.summary,
      });
    } catch {
      // 파싱 실패한 피드백은 스킵
    }
  }

  if (history.length === 0) return undefined;

  // 구조화된 컨텍스트 문자열 생성
  const lines: string[] = ["Previous feedback history:"];

  for (let i = 0; i < history.length; i++) {
    const h = history[i];
    const errorsStr = h.errors.length > 0 ? h.errors.join("; ") : "no errors";
    lines.push(`[${i + 1}] "${h.recognized_text}" — ${errorsStr}`);
  }

  const lastSummary = history[history.length - 1].summary;
  lines.push(`Latest summary: ${lastSummary}`);

  let result = lines.join("\n");

  // 길이 제한
  if (result.length > MAX_CONTEXT_CHARS) {
    result = result.slice(0, MAX_CONTEXT_CHARS - 3) + "...";
  }

  return result;
}
