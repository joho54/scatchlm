import React from "react";
import { View, Text, ScrollView, StyleSheet } from "react-native";
import type { FeedbackResponse } from "../types";

interface FeedbackOverlayProps {
  feedback: FeedbackResponse;
}

export default function FeedbackOverlay({ feedback }: FeedbackOverlayProps) {
  return (
    <View style={styles.container}>
      <ScrollView style={styles.scroll} showsVerticalScrollIndicator={false}>
        {/* 인식된 텍스트 */}
        <Text style={styles.sectionTitle}>인식된 텍스트</Text>
        <Text style={styles.recognizedText}>{feedback.recognized_text}</Text>

        {/* 교정 내용 */}
        {feedback.corrections.length > 0 && (
          <>
            <Text style={styles.sectionTitle}>교정</Text>
            {feedback.corrections.map((c, i) => (
              <View key={i} style={styles.correctionCard}>
                <View style={styles.correctionRow}>
                  <Text style={styles.original}>{c.original}</Text>
                  <Text style={styles.arrow}> → </Text>
                  <Text style={styles.corrected}>{c.corrected}</Text>
                </View>
                <Text style={styles.reason}>{c.reason}</Text>
              </View>
            ))}
          </>
        )}

        {/* 총평 */}
        <Text style={styles.sectionTitle}>총평</Text>
        <Text style={styles.summary}>{feedback.summary}</Text>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: "#F0F4FF",
    borderTopWidth: 1,
    borderTopColor: "#D0D8F0",
    maxHeight: 240,
  },
  scroll: {
    padding: 12,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: "700",
    color: "#4A5568",
    marginTop: 8,
    marginBottom: 4,
  },
  recognizedText: {
    fontSize: 15,
    color: "#2D3748",
    backgroundColor: "#fff",
    padding: 8,
    borderRadius: 6,
    overflow: "hidden",
  },
  correctionCard: {
    backgroundColor: "#fff",
    borderRadius: 6,
    padding: 8,
    marginBottom: 6,
    borderLeftWidth: 3,
    borderLeftColor: "#E53E3E",
  },
  correctionRow: {
    flexDirection: "row",
    alignItems: "center",
    flexWrap: "wrap",
  },
  original: {
    fontSize: 14,
    color: "#E53E3E",
    textDecorationLine: "line-through",
  },
  arrow: {
    fontSize: 14,
    color: "#718096",
  },
  corrected: {
    fontSize: 14,
    color: "#38A169",
    fontWeight: "600",
  },
  reason: {
    fontSize: 12,
    color: "#718096",
    marginTop: 4,
  },
  summary: {
    fontSize: 14,
    color: "#2D3748",
    backgroundColor: "#fff",
    padding: 8,
    borderRadius: 6,
    lineHeight: 20,
  },
});
