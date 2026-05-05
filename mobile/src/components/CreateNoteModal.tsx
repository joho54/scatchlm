import React, { useEffect, useState } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  Modal,
  StyleSheet,
  ActivityIndicator,
  ScrollView,
} from "react-native";
import { BlurView } from "expo-blur";
import Svg, { Path, Polyline, Line } from "react-native-svg";
import { useTextbookStore } from "../stores/textbookStore";
import type { TextbookListItem } from "../services/textbook";

interface CreateNoteModalProps {
  visible: boolean;
  recentLanguages: string[];
  onClose: () => void;
  onCreate: (title: string, language: string, textbook?: { id: string; name: string; pages: number }) => void;
}

export default function CreateNoteModal({ visible, recentLanguages, onClose, onCreate }: CreateNoteModalProps) {
  const [title, setTitle] = useState("");
  const [language, setLanguage] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const { textbooks, loading, loadTextbooks, uploadTextbook } = useTextbookStore();
  const [uploading, setUploading] = useState(false);

  useEffect(() => {
    if (visible) {
      loadTextbooks();
      setTitle("");
      setLanguage(recentLanguages[0] ?? "");
      setSelectedId(null);
    }
  }, [visible]);

  const handleCreate = () => {
    const selected = textbooks.find((t) => t.id === selectedId);
    onCreate(
      title.trim() || "Untitled note",
      language.trim() || "en",
      selected ? { id: selected.id, name: selected.fileName, pages: selected.totalPages } : undefined,
    );
  };

  const handleUpload = async () => {
    setUploading(true);
    try {
      const item = await uploadTextbook();
      if (item) setSelectedId(item.id);
    } catch {}
    setUploading(false);
  };

  const toggleSelect = (id: string) => {
    setSelectedId((prev) => (prev === id ? null : id));
  };

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <TouchableOpacity style={styles.overlay} activeOpacity={1} onPress={onClose}>
        <BlurView intensity={40} tint="dark" style={StyleSheet.absoluteFill} />
        <TouchableOpacity activeOpacity={1} onPress={() => {}}>
          <View style={styles.modal}>
            <Text style={styles.modalTitle}>New Note</Text>

            {/* Title */}
            <View style={styles.field}>
              <Text style={styles.label}>Title</Text>
              <TextInput
                style={styles.input}
                placeholder="Untitled note"
                placeholderTextColor="#aeaeb2"
                value={title}
                onChangeText={setTitle}
                autoFocus
              />
            </View>

            {/* Target Language */}
            <View style={styles.field}>
              <Text style={styles.label}>Target language</Text>
              <TextInput
                style={styles.input}
                placeholder="e.g. Japanese, Ancient Greek"
                placeholderTextColor="#aeaeb2"
                value={language}
                onChangeText={setLanguage}
              />
              {recentLanguages.length > 0 && (
                <View style={styles.langChips}>
                  {recentLanguages.map((lang) => (
                    <TouchableOpacity
                      key={lang}
                      style={[styles.langChip, language === lang && styles.langChipSelected]}
                      onPress={() => setLanguage(lang)}
                    >
                      <Text style={[styles.langChipText, language === lang && styles.langChipTextSelected]}>
                        {lang}
                      </Text>
                    </TouchableOpacity>
                  ))}
                </View>
              )}
            </View>

            {/* Textbook */}
            <View style={styles.field}>
              <Text style={styles.label}>Textbook (optional)</Text>
              {loading ? (
                <ActivityIndicator style={{ marginVertical: 16 }} />
              ) : (
                <ScrollView style={styles.textbookList} bounces={false}>
                  {textbooks.map((tb) => (
                    <TouchableOpacity
                      key={tb.id}
                      style={[styles.tbOption, selectedId === tb.id && styles.tbOptionSelected]}
                      onPress={() => toggleSelect(tb.id)}
                    >
                      <View style={[styles.tbIcon, selectedId === tb.id && styles.tbIconSelected]}>
                        <Svg width={16} height={16} viewBox="0 0 24 24" fill="none" stroke={selectedId === tb.id ? "#fff" : "#5856d6"} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
                          <Path d="M4 19.5A2.5 2.5 0 016.5 17H20" />
                          <Path d="M6.5 2H20v20H6.5A2.5 2.5 0 014 19.5v-15A2.5 2.5 0 016.5 2z" />
                        </Svg>
                      </View>
                      <View style={styles.tbInfo}>
                        <Text style={styles.tbName} numberOfLines={1}>{tb.fileName}</Text>
                        <Text style={styles.tbPages}>{tb.totalPages} pages</Text>
                      </View>
                      <View style={[styles.tbCheck, selectedId === tb.id && styles.tbCheckSelected]}>
                        {selectedId === tb.id && (
                          <Svg width={12} height={12} viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth={3} strokeLinecap="round" strokeLinejoin="round">
                            <Polyline points="20 6 9 17 4 12" />
                          </Svg>
                        )}
                      </View>
                    </TouchableOpacity>
                  ))}

                  {/* Upload new */}
                  <TouchableOpacity style={styles.uploadBtn} onPress={handleUpload} disabled={uploading}>
                    {uploading ? (
                      <ActivityIndicator size="small" />
                    ) : (
                      <>
                        <Svg width={16} height={16} viewBox="0 0 24 24" fill="none" stroke="#aeaeb2" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
                          <Path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" />
                          <Polyline points="17 8 12 3 7 8" />
                          <Line x1="12" y1="3" x2="12" y2="15" />
                        </Svg>
                        <Text style={styles.uploadText}>Upload new PDF</Text>
                      </>
                    )}
                  </TouchableOpacity>
                </ScrollView>
              )}
            </View>

            {/* Actions */}
            <View style={styles.actions}>
              <TouchableOpacity style={styles.btnCancel} onPress={onClose}>
                <Text style={styles.btnCancelText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.btnCreate} onPress={handleCreate}>
                <Text style={styles.btnCreateText}>Create</Text>
              </TouchableOpacity>
            </View>
          </View>
        </TouchableOpacity>
      </TouchableOpacity>
    </Modal>
  );
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
  },
  modal: {
    width: 400,
    backgroundColor: "rgba(255,255,255,0.85)",
    borderRadius: 20,
    padding: 28,
    paddingTop: 24,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 8 },
    shadowOpacity: 0.15,
    shadowRadius: 40,
    elevation: 20,
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: "700",
    color: "#1c1c1e",
    marginBottom: 20,
  },
  field: {
    marginBottom: 16,
  },
  label: {
    fontSize: 13,
    fontWeight: "600",
    color: "#8e8e93",
    marginBottom: 6,
  },
  input: {
    padding: 10,
    paddingHorizontal: 12,
    borderWidth: 1,
    borderColor: "rgba(0,0,0,0.08)",
    borderRadius: 10,
    fontSize: 15,
    backgroundColor: "rgba(255,255,255,0.6)",
    color: "#1c1c1e",
  },
  langChips: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 6,
    marginTop: 8,
  },
  langChip: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 14,
    backgroundColor: "rgba(0,0,0,0.05)",
  },
  langChipSelected: {
    backgroundColor: "#5856d6",
  },
  langChipText: {
    fontSize: 12,
    color: "#636366",
  },
  langChipTextSelected: {
    color: "#fff",
  },
  textbookList: {
    maxHeight: 200,
  },
  tbOption: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    padding: 10,
    paddingHorizontal: 12,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(0,0,0,0.06)",
    backgroundColor: "rgba(255,255,255,0.5)",
    marginBottom: 8,
  },
  tbOptionSelected: {
    borderColor: "#5856d6",
    backgroundColor: "#f0efff",
  },
  tbIcon: {
    width: 32,
    height: 32,
    borderRadius: 8,
    backgroundColor: "#f0efff",
    alignItems: "center",
    justifyContent: "center",
  },
  tbIconSelected: {
    backgroundColor: "#5856d6",
  },
  tbInfo: {
    flex: 1,
  },
  tbName: {
    fontSize: 14,
    fontWeight: "500",
    color: "#1c1c1e",
  },
  tbPages: {
    fontSize: 12,
    color: "#aeaeb2",
  },
  tbCheck: {
    width: 20,
    height: 20,
    borderRadius: 10,
    borderWidth: 2,
    borderColor: "#e5e5ea",
    alignItems: "center",
    justifyContent: "center",
  },
  tbCheckSelected: {
    borderColor: "#5856d6",
    backgroundColor: "#5856d6",
  },
  uploadBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    padding: 10,
    borderRadius: 10,
    borderWidth: 1,
    borderStyle: "dashed",
    borderColor: "#e5e5ea",
    marginBottom: 4,
  },
  uploadText: {
    fontSize: 13,
    color: "#aeaeb2",
  },
  actions: {
    flexDirection: "row",
    gap: 8,
    marginTop: 20,
  },
  btnCancel: {
    flex: 1,
    height: 42,
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.05)",
    alignItems: "center",
    justifyContent: "center",
  },
  btnCancelText: {
    fontSize: 15,
    fontWeight: "600",
    color: "#8e8e93",
  },
  btnCreate: {
    flex: 1,
    height: 42,
    borderRadius: 10,
    backgroundColor: "#1c1c1e",
    alignItems: "center",
    justifyContent: "center",
  },
  btnCreateText: {
    fontSize: 15,
    fontWeight: "600",
    color: "#fff",
  },
});
