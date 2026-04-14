import axios from "axios";
import { supabase } from "./supabase";
import logger from "./logger";

const api = axios.create({
  baseURL: "http://192.168.0.27:8000/api",
  timeout: 30000,
});

api.interceptors.request.use(async (config) => {
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (session?.access_token) {
    config.headers.Authorization = `Bearer ${session.access_token}`;
  }
  logger.debug("api", `→ ${config.method?.toUpperCase()} ${config.url}`);
  return config;
});

api.interceptors.response.use(
  (response) => {
    logger.debug("api", `← ${response.status} ${response.config.url}`);
    return response;
  },
  (error) => {
    const status = error.response?.status ?? "network";
    const detail = error.response?.data?.detail ?? error.message;
    logger.error("api", `← ${status} ${error.config?.url}`, { detail });
    return Promise.reject(error);
  }
);

export default api;
