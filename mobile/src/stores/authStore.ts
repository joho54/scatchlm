import { create } from "zustand";
import { Session } from "@supabase/supabase-js";
import { supabase } from "../services/supabase";
import logger from "../services/logger";

interface AuthState {
  session: Session | null;
  loading: boolean;
  setSession: (session: Session | null) => void;
  signUp: (email: string, password: string) => Promise<string | null>;
  signIn: (email: string, password: string) => Promise<string | null>;
  signOut: () => Promise<void>;
  initialize: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set) => ({
  session: null,
  loading: true,

  setSession: (session) => set({ session }),

  signUp: async (email, password) => {
    logger.info("auth", "signUp attempt", { email });
    const { error } = await supabase.auth.signUp({ email, password });
    if (error) {
      logger.error("auth", "signUp failed", { error: error.message });
    } else {
      logger.info("auth", "signUp success", { email });
    }
    return error?.message ?? null;
  },

  signIn: async (email, password) => {
    logger.info("auth", "signIn attempt", { email });
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });
    if (error) {
      logger.error("auth", "signIn failed", { error: error.message });
    } else {
      logger.info("auth", "signIn success", { email });
    }
    return error?.message ?? null;
  },

  signOut: async () => {
    logger.info("auth", "signOut");
    await supabase.auth.signOut();
    set({ session: null });
  },

  initialize: async () => {
    logger.info("auth", "initialize start");
    const {
      data: { session },
    } = await supabase.auth.getSession();
    logger.info("auth", "session loaded", {
      hasSession: !!session,
      userId: session?.user?.id ?? null,
    });
    set({ session, loading: false });

    supabase.auth.onAuthStateChange((event, session) => {
      logger.info("auth", "state change", { event, userId: session?.user?.id ?? null });
      set({ session });
    });
  },
}));
