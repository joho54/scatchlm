#!/usr/bin/env bash
#
# data-durability-spec §B.4 Track D — app_logs 보존(retention).
# 90일 초과 로그를 삭제해 무한 증식을 막는다. durability는 Part A의 DB 덤프가 커버하므로
# 오래된 라인은 잘라도 안전(필요 시 덤프에서 복원).
#
# VM cron 등록(수동, 주 1회 정도면 충분):
#   23 4 * * 0 /opt/scatchlm/scripts/prune_app_logs.sh >> /var/log/scatchlm-prune.log 2>&1
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/scatchlm}"
RETENTION_DAYS="${APP_LOG_RETENTION_DAYS:-90}"
PGUSER="${POSTGRES_USER:-postgres}"
DB="${POSTGRES_DB:-scatchlm}"

cd "$STACK_DIR"

echo "[prune] $(date -Is) deleting app_logs older than ${RETENTION_DAYS}d"
docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres \
  psql -U "$PGUSER" -d "$DB" -c \
  "DELETE FROM app_logs WHERE ts < now() - interval '${RETENTION_DAYS} days';"
echo "[prune] $(date -Is) done"
