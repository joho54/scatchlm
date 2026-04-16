import { useEffect, useState } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  Alert,
  TextInput,
} from "react-native";
import { useRouter } from "expo-router";
import { useNoteStore } from "../src/stores/noteStore";
import { useAuthStore } from "../src/stores/authStore";
import logger from "../src/services/logger";

export default function HomeScreen() {
  const router = useRouter();
  const { notes, loading, loadNotes, createNote, deleteNote } = useNoteStore();
  const { signOut } = useAuthStore();
  const [showInput, setShowInput] = useState(false);
  const [newTitle, setNewTitle] = useState("");

  useEffect(() => {
    loadNotes();
  }, []);

  const handleCreate = async () => {
    const title = newTitle.trim() || "새 노트";
    const note = await createNote(title);
    setNewTitle("");
    setShowInput(false);
    logger.info("nav", "push /note", { noteId: note.id });
    router.push(`/note/${note.id}`);
  };

  const handleDelete = (id: string, title: string) => {
    Alert.alert("노트 삭제", `"${title}"를 삭제할까요?`, [
      { text: "취소", style: "cancel" },
      {
        text: "삭제",
        style: "destructive",
        onPress: () => deleteNote(id),
      },
    ]);
  };

  const formatDate = (iso: string) => {
    const d = new Date(iso);
    return `${d.getFullYear()}.${d.getMonth() + 1}.${d.getDate()}`;
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => router.push("/settings")}>
          <Text style={styles.headerButton}>설정</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={() => router.push("/poc-pencilkit")}>
          <Text style={[styles.headerButton, { color: "#E11D48" }]}>PKit POC</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={signOut}>
          <Text style={[styles.headerButton, { color: "#999" }]}>로그아웃</Text>
        </TouchableOpacity>
      </View>

      {showInput && (
        <View style={styles.inputRow}>
          <TextInput
            style={styles.input}
            placeholder="노트 제목"
            value={newTitle}
            onChangeText={setNewTitle}
            autoFocus
            onSubmitEditing={handleCreate}
          />
          <TouchableOpacity style={styles.confirmButton} onPress={handleCreate}>
            <Text style={styles.confirmText}>생성</Text>
          </TouchableOpacity>
        </View>
      )}

      {loading ? (
        <View style={styles.empty}>
          <Text style={styles.emptyText}>로딩 중...</Text>
        </View>
      ) : notes.length === 0 ? (
        <View style={styles.empty}>
          <Text style={styles.emptyText}>노트가 없습니다</Text>
          <Text style={styles.emptySubtext}>
            아래 + 버튼으로 새 노트를 만들어보세요
          </Text>
        </View>
      ) : (
        <FlatList
          data={notes}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.list}
          renderItem={({ item }) => (
            <TouchableOpacity
              style={styles.noteCard}
              onPress={() => {
                logger.info("nav", "push /note", { noteId: item.id });
                router.push(`/note/${item.id}`);
              }}
              onLongPress={() => handleDelete(item.id, item.title)}
            >
              <Text style={styles.noteTitle}>{item.title}</Text>
              <Text style={styles.noteDate}>{formatDate(item.updated_at)}</Text>
            </TouchableOpacity>
          )}
        />
      )}

      <TouchableOpacity
        style={styles.fab}
        onPress={() => setShowInput(!showInput)}
      >
        <Text style={styles.fabText}>+</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#f5f5f5" },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 4,
  },
  headerButton: { fontSize: 15, color: "#007AFF" },
  inputRow: {
    flexDirection: "row",
    paddingHorizontal: 16,
    paddingVertical: 8,
    gap: 8,
  },
  input: {
    flex: 1,
    borderWidth: 1,
    borderColor: "#ddd",
    borderRadius: 8,
    padding: 12,
    fontSize: 16,
    backgroundColor: "#fff",
  },
  confirmButton: {
    backgroundColor: "#000",
    borderRadius: 8,
    paddingHorizontal: 16,
    justifyContent: "center",
  },
  confirmText: { color: "#fff", fontSize: 15, fontWeight: "600" },
  list: { padding: 16, gap: 8 },
  noteCard: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 16,
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.05,
    shadowRadius: 2,
    elevation: 1,
  },
  noteTitle: { fontSize: 16, fontWeight: "500", flex: 1 },
  noteDate: { fontSize: 13, color: "#999", marginLeft: 12 },
  empty: { flex: 1, justifyContent: "center", alignItems: "center" },
  emptyText: { fontSize: 18, color: "#999" },
  emptySubtext: { fontSize: 14, color: "#bbb", marginTop: 8 },
  fab: {
    position: "absolute",
    bottom: 32,
    right: 24,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: "#000",
    justifyContent: "center",
    alignItems: "center",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.2,
    shadowRadius: 4,
    elevation: 4,
  },
  fabText: { color: "#fff", fontSize: 28, lineHeight: 30 },
});
