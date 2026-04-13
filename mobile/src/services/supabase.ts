import "react-native-url-polyfill/auto";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { createClient } from "@supabase/supabase-js";

const SUPABASE_URL = "https://iuuhjgnlxzakdrsuobuh.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_tpIT1v44gNDeooIndTnfeQ__cUr3EGo";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    storage: AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});
