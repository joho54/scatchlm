import React from "react";
import { View, Text, StyleSheet, ScrollView, Platform } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

let LiquidGlassView: any = null;
if (Platform.OS === "ios") {
  try {
    const mod = require("expo-liquid-glass");
    LiquidGlassView = mod.default;
  } catch (e) {
    console.log("[liquid-glass] require failed:", e);
  }
}

export default function PocLiquidGlass() {
  const insets = useSafeAreaInsets();

  if (!LiquidGlassView) {
    return (
      <View style={[styles.container, { paddingTop: insets.top }]}>
        <Text style={styles.error}>expo-liquid-glass not available</Text>
      </View>
    );
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Dense scrollable text background */}
      <ScrollView style={styles.scroll} contentContainerStyle={styles.scrollContent}>
        {Array.from({ length: 8 }, (_, section) => (
          <View key={section}>
            <Text style={styles.heading}>Section {section + 1} — Grammar Drill</Text>
            {Array.from({ length: 30 }, (_, i) => (
              <Text key={i} style={styles.dense}>
                {`${section * 30 + i + 1}. The quick brown fox jumps over the lazy dog — she runs, he flies, they carry, we study hard every day.`}
              </Text>
            ))}
          </View>
        ))}
        <View style={{ height: 300 }} />
      </ScrollView>

      {/* Liquid Glass: Back button */}
      <LiquidGlassView style={styles.backBtn} radius={18}>
        <Text style={styles.backIcon}>‹</Text>
      </LiquidGlassView>

      {/* Liquid Glass: FAB pill */}
      <LiquidGlassView style={styles.fabPill} radius={28}>
        <View style={styles.pillInner}>
          <Text style={styles.pillIcon}>📖</Text>
          <View style={styles.pillDivider} />
          <Text style={styles.pillIcon}>✦</Text>
        </View>
      </LiquidGlassView>

      {/* Liquid Glass: Larger card to show lens effect */}
      <LiquidGlassView style={styles.card} radius={16}>
        <Text style={styles.cardTitle}>Feedback</Text>
        <Text style={styles.cardText}>1. runs — Correct!</Text>
        <Text style={styles.cardText}>2. flys → flies</Text>
      </LiquidGlassView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#fff" },
  scroll: { flex: 1 },
  scrollContent: { padding: 16, paddingTop: 0 },
  heading: {
    fontSize: 18,
    fontWeight: "700",
    color: "#111",
    marginTop: 16,
    marginBottom: 4,
  },
  dense: {
    fontSize: 14,
    lineHeight: 22,
    color: "#1a1a2e",
  },
  backBtn: {
    position: "absolute",
    top: 12,
    left: 16,
    width: 44,
    height: 44,
    justifyContent: "center",
    alignItems: "center",
  },
  backIcon: {
    fontSize: 28,
    fontWeight: "300",
    color: "#1c1c1e",
  },
  fabPill: {
    position: "absolute",
    bottom: 24,
    left: 20,
    height: 56,
    paddingHorizontal: 6,
    justifyContent: "center",
  },
  pillInner: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    paddingHorizontal: 10,
  },
  pillIcon: { fontSize: 22, paddingHorizontal: 8 },
  pillDivider: { width: 1, height: 24, backgroundColor: "rgba(0,0,0,0.1)" },
  card: {
    position: "absolute",
    bottom: 100,
    left: 20,
    right: 20,
    padding: 16,
  },
  cardTitle: { fontSize: 15, fontWeight: "600", color: "#1c1c1e", marginBottom: 6 },
  cardText: { fontSize: 14, color: "#333", lineHeight: 22 },
  error: { fontSize: 16, color: "#ff3b30", textAlign: "center", marginTop: 100 },
});
