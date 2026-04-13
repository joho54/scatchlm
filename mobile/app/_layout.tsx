import { useEffect } from "react";
import { Stack } from "expo-router";
import { useAuthStore } from "../src/stores/authStore";

export default function RootLayout() {
  const { session, loading, initialize } = useAuthStore();

  useEffect(() => {
    initialize();
  }, []);

  if (loading) return null;

  return (
    <Stack>
      {session ? (
        <>
          <Stack.Screen name="index" options={{ title: "ScatchLM" }} />
          <Stack.Screen
            name="note/[id]"
            options={{ title: "노트", headerBackTitle: "목록" }}
          />
          <Stack.Screen name="settings" options={{ title: "설정" }} />
        </>
      ) : (
        <Stack.Screen
          name="login"
          options={{ title: "로그인", headerShown: false }}
        />
      )}
    </Stack>
  );
}
