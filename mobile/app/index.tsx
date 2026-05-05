import { useCallback, useEffect, useState } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  Alert,
  TextInput,
  useWindowDimensions,
} from "react-native";
import { BlurView } from "expo-blur";
import { useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import Svg, { Path, Circle, Line, Polyline } from "react-native-svg";

import NoteCard from "../src/components/NoteCard";
import CreateNoteModal from "../src/components/CreateNoteModal";
import { useNoteStore } from "../src/stores/noteStore";
import { useAuthStore } from "../src/stores/authStore";
import type { NoteRow } from "../src/services/database";
import logger from "../src/services/logger";

const CARD_MIN_WIDTH = 240;
const CARD_GAP = 16;
const HORIZONTAL_PADDING = 32;

export default function HomeScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { width: screenWidth } = useWindowDimensions();
  const { notes, loading, loadNotes, createNote, deleteNote } = useNoteStore();
  const { signOut } = useAuthStore();
  const [modalVisible, setModalVisible] = useState(false);
  const [search, setSearch] = useState("");

  useEffect(() => {
    loadNotes();
  }, []);

  const numColumns = Math.max(1, Math.floor((screenWidth - HORIZONTAL_PADDING * 2 + CARD_GAP) / (CARD_MIN_WIDTH + CARD_GAP)));

  const filteredNotes = search
    ? notes.filter((n) => n.title.toLowerCase().includes(search.toLowerCase()))
    : notes;

  const recentLanguages = [...new Set(notes.map((n) => n.language).filter(Boolean))];

  const handleCreate = useCallback(
    async (title: string, language: string, textbook?: { id: string; name: string; pages: number }) => {
      setModalVisible(false);
      const note = await createNote(title, language, textbook);
      logger.info("nav", "push /note", { noteId: note.id });
      router.push(`/note/${note.id}`);
    },
    [createNote, router],
  );

  const handleDelete = useCallback(
    (id: string, title: string) => {
      Alert.alert("Delete note", `Delete "${title}"?`, [
        { text: "Cancel", style: "cancel" },
        { text: "Delete", style: "destructive", onPress: () => deleteNote(id) },
      ]);
    },
    [deleteNote],
  );

  const renderItem = useCallback(
    ({ item }: { item: NoteRow }) => (
      <View style={{ flex: 1 / numColumns, padding: CARD_GAP / 2 }}>
        <NoteCard
          note={item}
          onPress={() => {
            logger.info("nav", "push /note", { noteId: item.id });
            router.push(`/note/${item.id}`);
          }}
          onLongPress={() => handleDelete(item.id, item.title)}
        />
      </View>
    ),
    [numColumns, router, handleDelete],
  );

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Notes</Text>
        <View style={styles.headerActions}>
          <TouchableOpacity style={styles.headerBtn} onPress={() => router.push("/poc-liquid-glass")}>
            <Text style={{ fontSize: 14, color: "#8e8e93" }}>🔬</Text>
          </TouchableOpacity>
          <TouchableOpacity style={styles.headerBtn} onPress={() => router.push("/settings")}>
            <Svg width={18} height={18} viewBox="0 0 24 24" fill="none" stroke="#8e8e93" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
              <Circle cx={12} cy={12} r={3} />
              <Path d="M12 1v2m0 18v2m-9-11h2m18 0h2m-3.3-6.7l-1.4 1.4M6.7 17.3l-1.4 1.4m0-13.4l1.4 1.4m10.6 10.6l1.4 1.4" />
            </Svg>
          </TouchableOpacity>
          <TouchableOpacity style={styles.headerBtn} onPress={signOut}>
            <Svg width={18} height={18} viewBox="0 0 24 24" fill="none" stroke="#8e8e93" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
              <Path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4" />
              <Polyline points="16 17 21 12 16 7" />
              <Line x1={21} y1={12} x2={9} y2={12} />
            </Svg>
          </TouchableOpacity>
        </View>
      </View>

      {/* Search */}
      <View style={styles.searchBar}>
        <Svg width={16} height={16} viewBox="0 0 24 24" fill="none" stroke="#aeaeb2" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
          <Circle cx={11} cy={11} r={8} />
          <Line x1={21} y1={21} x2={16.65} y2={16.65} />
        </Svg>
        <TextInput
          style={styles.searchInput}
          placeholder="Search notes..."
          placeholderTextColor="#aeaeb2"
          value={search}
          onChangeText={setSearch}
        />
      </View>

      {/* Note Grid */}
      {loading ? (
        <View style={styles.empty}>
          <Text style={styles.emptyText}>Loading...</Text>
        </View>
      ) : filteredNotes.length === 0 ? (
        <View style={styles.empty}>
          <Svg width={64} height={64} viewBox="0 0 24 24" fill="none" stroke="#aeaeb2" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round" opacity={0.4}>
            <Path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z" />
            <Polyline points="14 2 14 8 20 8" />
            <Line x1={12} y1={18} x2={12} y2={12} />
            <Line x1={9} y1={15} x2={15} y2={15} />
          </Svg>
          <Text style={styles.emptyTitle}>
            {search ? "No matching notes" : "No notes yet"}
          </Text>
          <Text style={styles.emptySub}>
            {search ? "Try a different search" : "Tap + to create your first note"}
          </Text>
        </View>
      ) : (
        <FlatList
          data={filteredNotes}
          keyExtractor={(item) => item.id}
          key={numColumns}
          numColumns={numColumns}
          contentContainerStyle={styles.grid}
          renderItem={renderItem}
        />
      )}

      {/* FAB */}
      <TouchableOpacity
        style={[styles.fab, { bottom: 24 + insets.bottom }]}
        onPress={() => setModalVisible(true)}
        activeOpacity={0.8}
      >
        <BlurView intensity={60} tint="light" style={StyleSheet.absoluteFill} />
        <Svg width={28} height={28} viewBox="0 0 24 24" fill="none" stroke="#1c1c1e" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round">
          <Line x1={12} y1={5} x2={12} y2={19} />
          <Line x1={5} y1={12} x2={19} y2={12} />
        </Svg>
      </TouchableOpacity>

      {/* Create Modal */}
      <CreateNoteModal
        visible={modalVisible}
        recentLanguages={recentLanguages}
        onClose={() => setModalVisible(false)}
        onCreate={handleCreate}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#f2f2f7",
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: HORIZONTAL_PADDING,
    paddingTop: 20,
  },
  headerTitle: {
    fontSize: 34,
    fontWeight: "800",
    letterSpacing: -0.5,
    color: "#1c1c1e",
  },
  headerActions: {
    marginLeft: "auto",
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  headerBtn: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: "rgba(255,255,255,0.85)",
    borderWidth: 1,
    borderColor: "rgba(0,0,0,0.06)",
    alignItems: "center",
    justifyContent: "center",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.06,
    shadowRadius: 3,
    elevation: 1,
  },
  searchBar: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    marginHorizontal: HORIZONTAL_PADDING,
    marginTop: 16,
    paddingVertical: 10,
    paddingHorizontal: 14,
    backgroundColor: "rgba(255,255,255,0.7)",
    borderWidth: 1,
    borderColor: "rgba(0,0,0,0.04)",
    borderRadius: 10,
  },
  searchInput: {
    flex: 1,
    fontSize: 15,
    color: "#1c1c1e",
    padding: 0,
  },
  grid: {
    padding: HORIZONTAL_PADDING - CARD_GAP / 2,
    paddingBottom: 100,
  },
  empty: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    gap: 8,
  },
  emptyTitle: {
    fontSize: 18,
    fontWeight: "600",
    color: "#8e8e93",
  },
  emptyText: {
    fontSize: 16,
    color: "#8e8e93",
  },
  emptySub: {
    fontSize: 14,
    color: "#aeaeb2",
  },
  fab: {
    position: "absolute",
    right: 32,
    width: 56,
    height: 56,
    borderRadius: 28,
    overflow: "hidden",
    alignItems: "center",
    justifyContent: "center",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.6)",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.10,
    shadowRadius: 16,
    elevation: 8,
  },
});
