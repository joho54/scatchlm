import React, { Component, ErrorInfo, ReactNode } from "react";
import { View, Text, StyleSheet, TouchableOpacity } from "react-native";
import logger from "../services/logger";

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

export default class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    logger.error("ErrorBoundary", error.message, {
      stack: error.stack?.slice(0, 500),
      componentStack: errorInfo.componentStack?.slice(0, 500),
    });
  }

  render() {
    if (this.state.hasError) {
      return (
        <View style={styles.container}>
          <Text style={styles.title}>오류가 발생했습니다</Text>
          <Text style={styles.message}>{this.state.error?.message}</Text>
          <TouchableOpacity
            style={styles.button}
            onPress={() => this.setState({ hasError: false, error: null })}
          >
            <Text style={styles.buttonText}>다시 시도</Text>
          </TouchableOpacity>
        </View>
      );
    }

    return this.props.children;
  }
}

const styles = StyleSheet.create({
  container: { flex: 1, justifyContent: "center", alignItems: "center", padding: 32 },
  title: { fontSize: 20, fontWeight: "bold", marginBottom: 12 },
  message: { fontSize: 14, color: "#666", textAlign: "center", marginBottom: 24 },
  button: { backgroundColor: "#007AFF", paddingHorizontal: 24, paddingVertical: 12, borderRadius: 8 },
  buttonText: { color: "#fff", fontSize: 16, fontWeight: "600" },
});
