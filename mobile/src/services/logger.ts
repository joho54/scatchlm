const LOG_SERVER = "http://192.168.0.27:8000/api/dev/log";
const BATCH_INTERVAL = 2000;
const MAX_QUEUE = 50;

interface LogEntry {
  level: string;
  tag: string;
  message: string;
  data?: Record<string, unknown>;
  timestamp: string;
}

let queue: LogEntry[] = [];
let timer: ReturnType<typeof setTimeout> | null = null;

function enqueue(level: string, tag: string, message: string, data?: Record<string, unknown>) {
  const entry: LogEntry = {
    level,
    tag,
    message,
    data,
    timestamp: new Date().toISOString(),
  };

  // 콘솔에도 출력
  const prefix = `[${tag}]`;
  if (level === "error") {
    console.error(prefix, message, data ?? "");
  } else if (level === "warn") {
    console.warn(prefix, message, data ?? "");
  } else {
    console.log(prefix, message, data ?? "");
  }

  queue.push(entry);

  if (queue.length >= MAX_QUEUE) {
    flush();
  } else if (!timer) {
    timer = setTimeout(flush, BATCH_INTERVAL);
  }
}

async function flush() {
  if (timer) {
    clearTimeout(timer);
    timer = null;
  }
  if (queue.length === 0) return;

  const batch = [...queue];
  queue = [];

  try {
    await fetch(`${LOG_SERVER}/batch`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ logs: batch }),
    });
  } catch {
    // 서버 미실행 시 무시 — 콘솔 출력은 이미 됨
  }
}

const logger = {
  info: (tag: string, message: string, data?: Record<string, unknown>) =>
    enqueue("info", tag, message, data),
  warn: (tag: string, message: string, data?: Record<string, unknown>) =>
    enqueue("warn", tag, message, data),
  error: (tag: string, message: string, data?: Record<string, unknown>) =>
    enqueue("error", tag, message, data),
  debug: (tag: string, message: string, data?: Record<string, unknown>) =>
    enqueue("debug", tag, message, data),
  flush,
};

export default logger;
