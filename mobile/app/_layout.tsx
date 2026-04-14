import React, { useEffect } from "react";
import { Stack, useRouter, useSegments, usePathname } from "expo-router";
import { useAuthStore } from "../src/stores/authStore";
import logger from "../src/services/logger";
import ErrorBoundary from "../src/components/ErrorBoundary";

function RootLayoutInner() {
  const { session, loading, initialize } = useAuthStore();
  const router = useRouter();
  const segments = useSegments();
  const pathname = usePathname();

  useEffect(() => {
    logger.info("app", "RootLayout mounted");
    initialize();
  }, []);

  // 라우트 변화 추적
  useEffect(() => {
    logger.info("nav", "route changed", { pathname, segments });
  }, [pathname]);

  useEffect(() => {
    if (loading) return;

    const inLoginPage = segments[0] === "login";

    if (!session && !inLoginPage) {
      logger.info("app", "no session, redirecting to login");
      router.replace("/login");
    } else if (session && inLoginPage) {
      logger.info("app", "session found, redirecting to home");
      router.replace("/");
    }
  }, [session, loading, segments]);

  if (loading) {
    logger.debug("app", "still loading auth...");
    return null;
  }

  logger.info("app", "render", { hasSession: !!session });

  return (
    <Stack>
      <Stack.Screen name="index" options={{ title: "ScatchLM" }} />
      <Stack.Screen
        name="login"
        options={{ title: "로그인", headerShown: false }}
      />
      <Stack.Screen
        name="note"
        options={{ headerShown: false }}
      />
      <Stack.Screen name="settings" options={{ title: "설정" }} />
    </Stack>
  );
}

export default function RootLayout() {
  return (
    <ErrorBoundary>
      <RootLayoutInner />
    </ErrorBoundary>
  );
}
