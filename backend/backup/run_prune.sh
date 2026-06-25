#!/usr/bin/env bash
#
# data-durability-spec §B.4 — app_logs 보존(retention). RETENTION_DAYS 초과 로그 삭제로
# 무한 증식 차단. durability는 Part A 덤프가 커버하므로 오래된 라인은 잘라도 안전.
set -euo pipefail

PGHOST="${POSTGRES_HOST:-postgres}"
DB="${POSTGRES_DB:-scatchlm}"
PGUSER="${POSTGRES_USER:-postgres}"
RET="${APP_LOG_RETENTION_DAYS:-90}"
export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"

echo "[prune] $(date -Is) deleting app_logs older than ${RET}d"
psql -h "$PGHOST" -U "$PGUSER" -d "$DB" -c \
  "DELETE FROM app_logs WHERE ts < now() - interval '${RET} days';"
echo "[prune] $(date -Is) done"
