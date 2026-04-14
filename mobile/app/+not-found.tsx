import { View, Text, StyleSheet, TouchableOpacity } from "react-native";
import { usePathname, useRouter } from "expo-router";
import logger from "../src/services/logger";

export default function NotFoundScreen() {
  const pathname = usePathname();
  const router = useRouter();

  logger.error("nav", "Unmatched route", { pathname });

  return (
    <View style={styles.container}>
      <Text style={styles.title}>페이지를 찾을 수 없습니다</Text>
      <Text style={styles.path}>{pathname}</Text>
      <TouchableOpacity style={styles.button} onPress={() => router.replace("/")}>
        <Text style={styles.buttonText}>홈으로 돌아가기</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, justifyContent: "center", alignItems: "center", padding: 32 },
  title: { fontSize: 20, fontWeight: "bold", marginBottom: 12 },
  path: { fontSize: 14, color: "#999", marginBottom: 24, fontFamily: "monospace" },
  button: { backgroundColor: "#007AFF", paddingHorizontal: 24, paddingVertical: 12, borderRadius: 8 },
  buttonText: { color: "#fff", fontSize: 16, fontWeight: "600" },
});
