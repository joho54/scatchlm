#!/usr/bin/env bash
#
# Postgres 논리 백업(custom -Fc, MVCC 단일시점 일관) → NCP Object Storage 스트림 업로드.
# 사이드카가 compose 네트워크로 postgres에 직접 접속(pg_dump -h postgres). VM 디스크에
# 덤프를 남기지 않는다(임시파일 없음 — upload_stream.py가 stdin을 멀티파트로 흘려보냄).
# 자격증명은 .env.prod의 OBJECT_STORAGE_*/POSTGRES_* 재사용.
set -euo pipefail

DATE="$(date +%F)"                       # YYYY-MM-DD (TZ=Asia/Seoul, compose env)
KEY="backups/db/scatchlm-${DATE}.dump"
PGHOST="${POSTGRES_HOST:-postgres}"
DB="${POSTGRES_DB:-scatchlm}"
PGUSER="${POSTGRES_USER:-postgres}"
export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"

echo "[backup] $(date -Is) start → s3://.../${KEY}"

# pipefail 켜져 있어 pg_dump 실패도 전체 실패로 전파된다.
if pg_dump -h "$PGHOST" -U "$PGUSER" -Fc "$DB" \
   | python3 /usr/local/bin/upload_stream.py "$KEY"; then
    echo "[backup] $(date -Is) OK → ${KEY}"
else
    rc=$?
    # 조용한 실패 = 백업 부재(2026-06-18 교훈). stdout/stderr는 supercronic이 docker logs로 노출하고,
    # 메커니즘-독립 백스톱(backup-freshness 알람)이 최신 덤프 26h 초과 시 메일로 잡는다.
    echo "[backup] $(date -Is) FAILED rc=${rc} key=${KEY}" >&2
    exit "$rc"
fi
