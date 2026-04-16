import React, { useMemo } from "react";
import { View, Text, StyleSheet } from "react-native";

interface FeedbackCardProps {
  recognizedText?: string;
  feedback?: string;
  summary?: string;
  text?: string; // 레거시 호환 (구조화 필드가 없을 때)
  y: number;
  width: number;
}

/**
 * 간단한 마크다운 파싱: ~~text~~ → 빨강 취소선, **text** → 초록 볼드
 * 한 줄 단위로 파싱한다.
 */
function parseFeedbackLine(line: string, lineIdx: number): React.ReactNode {
  // ~~...~~ 와 **...** 를 번갈아 파싱
  const parts: React.ReactNode[] = [];
  const regex = /(\*\*(.+?)\*\*)|(~~(.+?)~~)/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  let partIdx = 0;

  while ((match = regex.exec(line)) !== null) {
    // 매치 전 일반 텍스트
    if (match.index > lastIndex) {
      parts.push(line.slice(lastIndex, match.index));
    }

    if (match[2]) {
      // **bold** → green bold (교정된 텍스트)
      parts.push(
        <Text key={`${lineIdx}-${partIdx++}`} style={styles.corrected}>
          {match[2]}
        </Text>
      );
    } else if (match[4]) {
      // ~~strikethrough~~ → red strikethrough (원본 오류)
      parts.push(
        <Text key={`${lineIdx}-${partIdx++}`} style={styles.original}>
          {match[4]}
        </Text>
      );
    }

    lastIndex = match.index + match[0].length;
  }

  // 나머지 텍스트
  if (lastIndex < line.length) {
    parts.push(line.slice(lastIndex));
  }

  return parts.length > 0 ? parts : line;
}

export default function FeedbackCard({
  recognizedText,
  feedback,
  summary,
  text,
  y,
  width,
}: FeedbackCardProps) {
  const hasStructured = !!(recognizedText || feedback || summary);

  const feedbackLines = useMemo(() => {
    if (!feedback) return [];
    return feedback.split("\n").filter((l) => l.trim().length > 0);
  }, [feedback]);

  // 레거시: 구조화 필드 없이 text만 있는 경우
  if (!hasStructured) {
    return (
      <View style={[styles.card, { top: y, width }]}>
        <Text style={styles.bodyText}>{text}</Text>
      </View>
    );
  }

  return (
    <View style={[styles.card, { top: y, width }]}>
      {/* recognized_text */}
      {recognizedText ? (
        <View style={styles.recognizedBox}>
          <Text style={styles.recognizedText}>{recognizedText}</Text>
        </View>
      ) : null}

      {/* feedback body */}
      {feedbackLines.length > 0 ? (
        <View style={styles.bodySection}>
          {feedbackLines.map((line, i) => (
            <Text key={i} style={styles.bodyText}>
              {parseFeedbackLine(line, i)}
            </Text>
          ))}
        </View>
      ) : null}

      {/* summary */}
      {summary ? (
        <View style={styles.summarySection}>
          <Text style={styles.summaryText}>{summary}</Text>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    position: "absolute",
    left: 20,
    backgroundColor: "rgba(255,255,255,0.55)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.6)",
    borderRadius: 14,
    padding: 14,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 12,
    elevation: 4,
  },
  recognizedBox: {
    backgroundColor: "rgba(0,0,0,0.03)",
    borderRadius: 6,
    paddingHorizontal: 10,
    paddingVertical: 8,
    marginBottom: 10,
  },
  recognizedText: {
    fontSize: 13,
    color: "#8e8e93",
    fontFamily: "Menlo",
    lineHeight: 20,
  },
  bodySection: {
    gap: 4,
  },
  bodyText: {
    fontSize: 14,
    lineHeight: 24,
    color: "#1c1c1e",
  },
  original: {
    color: "#ff3b30",
    textDecorationLine: "line-through",
  },
  corrected: {
    color: "#34c759",
    fontWeight: "700",
  },
  summarySection: {
    marginTop: 10,
    paddingTop: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#f0f0f2",
  },
  summaryText: {
    fontSize: 13,
    color: "#8e8e93",
    lineHeight: 20,
  },
});
