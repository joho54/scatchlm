import { Stack } from "expo-router";

export default function RootLayout() {
  return (
    <Stack>
      <Stack.Screen name="index" options={{ title: "ScatchLM" }} />
      <Stack.Screen
        name="note/[id]"
        options={{ title: "노트", headerBackTitle: "목록" }}
      />
      <Stack.Screen name="settings" options={{ title: "설정" }} />
    </Stack>
  );
}
