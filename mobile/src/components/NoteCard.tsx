import React from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import Svg, { Path } from "react-native-svg";
import type { NoteRow } from "../services/database";

interface NoteCardProps {
  note: NoteRow;
  onPress: () => void;
  onLongPress: () => void;
}

function formatDate(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}.${d.getMonth() + 1}.${d.getDate()}`;
}

const LINE_HEIGHT = 24;
const LINES_COUNT = 7;

function ThumbLines() {
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      {Array.from({ length: LINES_COUNT }, (_, i) => (
        <View
          key={i}
          style={{
            position: "absolute",
            left: 0,
            right: 0,
            height: 1,
            top: LINE_HEIGHT * (i + 1),
            backgroundColor: "#eef0f3",
            opacity: 0.6,
          }}
        />
      ))}
    </View>
  );
}

export default function NoteCard({ note, onPress, onLongPress }: NoteCardProps) {
  const lang = (note.language || "en").toUpperCase();

  return (
    <TouchableOpacity
      style={styles.card}
      onPress={onPress}
      onLongPress={onLongPress}
      activeOpacity={0.7}
    >
      {/* Thumbnail */}
      <View style={styles.thumb}>
        <ThumbLines />
        {note.textbook_id && (
          <View style={styles.badge}>
            <Svg width={12} height={12} viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round">
              <Path d="M4 19.5A2.5 2.5 0 016.5 17H20" />
              <Path d="M6.5 2H20v20H6.5A2.5 2.5 0 014 19.5v-15A2.5 2.5 0 016.5 2z" />
            </Svg>
          </View>
        )}
      </View>

      {/* Info */}
      <View style={styles.info}>
        <Text style={styles.title} numberOfLines={1}>
          {note.title}
        </Text>
        <View style={styles.meta}>
          <View style={styles.langBadge}>
            <Text style={styles.langText}>{lang}</Text>
          </View>
          <Text style={styles.date}>{formatDate(note.updated_at)}</Text>
        </View>
      </View>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: "#fff",
    borderRadius: 14,
    overflow: "hidden",
    borderWidth: 1,
    borderColor: "rgba(0,0,0,0.04)",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.06,
    shadowRadius: 3,
    elevation: 1,
  },
  thumb: {
    height: 160,
    backgroundColor: "#fff",
    borderBottomWidth: 1,
    borderBottomColor: "#f0f0f2",
    position: "relative",
  },
  langBadge: {
    paddingHorizontal: 6,
    paddingVertical: 1,
    borderRadius: 4,
    backgroundColor: "#e8f2ff",
  },
  langText: {
    fontSize: 11,
    fontWeight: "600",
    color: "#007aff",
  },
  badge: {
    position: "absolute",
    top: 8,
    right: 8,
    width: 24,
    height: 24,
    borderRadius: 12,
    backgroundColor: "#5856d6",
    alignItems: "center",
    justifyContent: "center",
  },
  info: {
    padding: 12,
    paddingHorizontal: 14,
  },
  title: {
    fontSize: 15,
    fontWeight: "600",
    color: "#1c1c1e",
  },
  meta: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    marginTop: 4,
  },
  date: {
    fontSize: 12,
    color: "#aeaeb2",
  },
});
