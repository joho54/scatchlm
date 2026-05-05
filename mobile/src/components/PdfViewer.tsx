import React, { useCallback, useEffect, useState } from "react";
import { StyleSheet, View, Text, TouchableOpacity } from "react-native";
import Pdf from "react-native-pdf";
import Constants from "expo-constants";
import { supabase } from "../services/supabase";

const apiHost = Constants.expoConfig?.extra?.apiHost;
if (!apiHost) throw new Error("apiHost not configured in app.config.js extra");
const API_BASE = `http://${apiHost}:8000`;

interface PdfViewerProps {
  textbookId: string;
  totalPages: number;
  initialPage?: number;
  onPageChanged: (page: number) => void;
  onClose: () => void;
}

export default function PdfViewer({
  textbookId,
  totalPages,
  initialPage = 1,
  onPageChanged,
  onClose,
}: PdfViewerProps) {
  const [currentPage, setCurrentPage] = useState(initialPage);
  const [token, setToken] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getSession();
      setToken(data.session?.access_token ?? null);
    })();
  }, []);

  const handlePageChanged = useCallback(
    (page: number, numberOfPages: number) => {
      console.log("[pdf] page changed:", page, "/", numberOfPages);
      setCurrentPage(page);
      onPageChanged(page);
    },
    [onPageChanged]
  );

  if (!token) {
    return (
      <View style={styles.container}>
        <Text style={styles.loadingText}>로딩 중...</Text>
      </View>
    );
  }

  const pdfUrl = `${API_BASE}/api/pdf/${textbookId}/file?token=${token}`;

  return (
    <View style={styles.container}>
      <View style={styles.topBar}>
        <Text style={styles.pageInfo}>
          {currentPage} / {totalPages}
        </Text>
        <TouchableOpacity onPress={onClose} style={styles.closeBtn}>
          <Text style={styles.closeBtnText}>X</Text>
        </TouchableOpacity>
      </View>

      <Pdf
        source={{ uri: pdfUrl }}
        page={initialPage}
        style={styles.pdf}
        enablePaging
        horizontal
        onPageChanged={(page, numberOfPages) => handlePageChanged(page, numberOfPages)}
        onError={(error) => console.log("[pdf] error:", error)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#f5f5f5" },
  topBar: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 6,
    paddingHorizontal: 8,
    backgroundColor: "#fff",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#ddd",
  },
  pageInfo: { fontSize: 13, color: "#333" },
  closeBtn: { position: "absolute", right: 8 },
  closeBtnText: { fontSize: 14, color: "#999", padding: 4 },
  pdf: { flex: 1 },
  loadingText: { textAlign: "center", marginTop: 40, color: "#999" },
});
