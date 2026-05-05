import React from "react";
import {
  View,
  TouchableOpacity,
  StyleSheet,
  Platform,
} from "react-native";
import Svg, { Path, Defs, LinearGradient, Stop } from "react-native-svg";

let LiquidGlassView: any = null;
if (Platform.OS === "ios") {
  try {
    LiquidGlassView = require("expo-liquid-glass").default;
  } catch {}
}

interface FloatingActionPillProps {
  onTogglePdf: () => void;
  onFeedback: () => void;
  pdfOpen: boolean;
  loading: boolean;
}

function BookIcon({ active }: { active: boolean }) {
  return (
    <Svg width={22} height={22} viewBox="0 0 24 24" fill="none" stroke={active ? "#fff" : "#8e8e93"} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
      <Path d="M4 19.5A2.5 2.5 0 016.5 17H20" />
      <Path d="M6.5 2H20v20H6.5A2.5 2.5 0 014 19.5v-15A2.5 2.5 0 016.5 2z" />
    </Svg>
  );
}

function SparkleIcon() {
  return (
    <Svg width={26} height={26} viewBox="0 0 28 28">
      <Defs>
        <LinearGradient id="ai-grad" x1="0%" y1="0%" x2="100%" y2="100%">
          <Stop offset="0%" stopColor="#1c1c1e" />
          <Stop offset="100%" stopColor="#636366" />
        </LinearGradient>
      </Defs>
      <Path
        d="M14 0 L15.8 10.5 L26 14 L15.8 17.5 L14 28 L12.2 17.5 L2 14 L12.2 10.5 Z"
        fill="url(#ai-grad)"
      />
      <Path
        d="M22 3 L22.8 6.2 L26 7 L22.8 7.8 L22 11 L21.2 7.8 L18 7 L21.2 6.2 Z"
        fill="url(#ai-grad)"
        opacity={0.6}
      />
    </Svg>
  );
}

function LoadingSpinner() {
  return <View style={styles.spinner} />;
}

export default function FloatingActionPill({
  onTogglePdf,
  onFeedback,
  pdfOpen,
  loading,
}: FloatingActionPillProps) {
  const content = (
    <>
      <TouchableOpacity
        style={[styles.btn, pdfOpen && styles.btnTextbookActive]}
        onPress={onTogglePdf}
        activeOpacity={0.7}
      >
        <BookIcon active={pdfOpen} />
      </TouchableOpacity>
      <View style={styles.divider} />
      <TouchableOpacity
        style={styles.btn}
        onPress={onFeedback}
        disabled={loading}
        activeOpacity={0.7}
      >
        {loading ? <LoadingSpinner /> : <SparkleIcon />}
      </TouchableOpacity>
    </>
  );

  // Use Liquid Glass on iOS, fallback on other platforms
  if (LiquidGlassView) {
    return (
      <LiquidGlassView style={styles.pill} radius={28}>
        <View style={styles.pillInner}>
          {content}
        </View>
      </LiquidGlassView>
    );
  }

  return (
    <View style={[styles.pill, styles.pillFallback]}>
      {content}
    </View>
  );
}

const styles = StyleSheet.create({
  pill: {
    position: "absolute",
    bottom: 20,
    right: 20,
    zIndex: 30,
    borderRadius: 28,
  },
  pillInner: {
    flexDirection: "row",
    alignItems: "center",
    gap: 2,
    padding: 4,
  },
  pillFallback: {
    flexDirection: "row",
    alignItems: "center",
    gap: 2,
    padding: 4,
    backgroundColor: "rgba(255,255,255,0.5)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.6)",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.1,
    shadowRadius: 16,
    elevation: 8,
  },
  btn: {
    width: 48,
    height: 48,
    borderRadius: 24,
    justifyContent: "center",
    alignItems: "center",
  },
  btnTextbookActive: {
    backgroundColor: "rgba(0,0,0,0.7)",
  },
  divider: {
    width: 1,
    height: 24,
    backgroundColor: "rgba(0,0,0,0.08)",
  },
  spinner: {
    width: 20,
    height: 20,
    borderRadius: 10,
    borderWidth: 2,
    borderColor: "rgba(0,0,0,0.1)",
    borderTopColor: "#1c1c1e",
  },
});
