#!/usr/bin/env bash
#
# data-durability-spec §A.4 — 버킷 덤프에서 Postgres 복구.
# 핵심: 빈 Postgres에 덤프를 부어 되살린다. 동일 VM 롤백 / VM 통째 유실 복구 양쪽에 쓴다.
#
# 사용:
#   bash restore_db.sh scatchlm-2026-06-04.dump      # 로컬에 받아둔 덤프로 복구
#   bash restore_db.sh --from-bucket 2026-06-04      # 버킷에서 받아 복구(날짜 지정)
#
# ⚠️ --clean --if-exists: 기존 객체를 DROP 후 재생성한다. 운영 DB에 직접 돌리기 전
#    반드시 영향 범위를 인지할 것(이 스크립트는 복구 드릴/재해 복구 전용).
#
# pgvector 함정(§A.5): 복원 대상 DB에 `CREATE EXTENSION vector`가 선행돼야 할 수 있다.
#    빈 DB로 새로 기동한 경우 app 컨테이너의 `alembic upgrade head`가 확장을 만들거나,
#    아래 PRE_RESTORE_SQL로 수동 생성한다.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/scatchlm}"
COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env.prod"
PGUSER="${POSTGRES_USER:-postgres}"
DB="${POSTGRES_DB:-scatchlm}"

cd "$STACK_DIR"

if [ "${1:-}" = "--from-bucket" ]; then
    DATE="${2:?usage: restore_db.sh --from-bucket <YYYY-MM-DD>}"
    DUMP="/tmp/scatchlm-${DATE}.dump"
    KEY="backups/db/scatchlm-${DATE}.dump"
    echo "[restore] downloading s3://.../${KEY}"
    # app 컨테이너 boto3로 버킷→stdout→로컬 파일 (aws CLI 불필요).
    $COMPOSE exec -T app python3 -c "
import os, sys, boto3
c = boto3.client('s3', endpoint_url=os.environ['OBJECT_STORAGE_ENDPOINT'],
    region_name=os.environ['OBJECT_STORAGE_REGION'],
    aws_access_key_id=os.environ['OBJECT_STORAGE_ACCESS_KEY'],
    aws_secret_access_key=os.environ['OBJECT_STORAGE_SECRET_KEY'])
c.download_fileobj('${OBJECT_STORAGE_BUCKET:-scatchlm-prod}', '${KEY}', sys.stdout.buffer)
" > "$DUMP"
else
    DUMP="${1:?usage: restore_db.sh <dump-file> | --from-bucket <YYYY-MM-DD>}"
fi

echo "[restore] (pgvector) ensuring extension exists"
$COMPOSE exec -T postgres psql -U "$PGUSER" -d "$DB" \
  -c "CREATE EXTENSION IF NOT EXISTS vector;" || true

echo "[restore] pg_restore → ${DB} (--clean --if-exists)"
$COMPOSE exec -T postgres pg_restore -U "$PGUSER" -d "$DB" --clean --if-exists < "$DUMP"

echo "[restore] done. 검증: row 수 확인"
$COMPOSE exec -T postgres psql -U "$PGUSER" -d "$DB" \
  -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"
