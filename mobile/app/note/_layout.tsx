import { Stack } from "expo-router";
import logger from "../../src/services/logger";

export default function NoteLayout() {
  logger.info("nav", "NoteLayout rendered");
  return (
    <Stack screenOptions={{ headerShown: false }} />
  );
}
