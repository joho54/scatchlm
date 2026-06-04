#!/usr/bin/env bash
#
# data-durability-spec §A.3 — Postgres 논리 백업 → NCP Object Storage (일배치).
#
# pg_dump(custom -Fc, MVCC 스냅샷 = 실행 중에도 단일 시점 일관 사본)을 파이프로
# app 컨테이너의 boto3 업로더에 흘려보낸다. **VM 디스크에 덤프를 남기지 않는다**
# (스트림 업로드 — 9.8G 루트 디스크 경쟁/누적 회피). 자격증명은 .env.prod의
# OBJECT_STORAGE_* 재사용 → 신규 인프라 0.
#
# 보존(retention)은 이 스크립트가 아니라 **버킷 lifecycle 규칙**이 관리한다(§A.3).
#
# VM 설치(수동, 1회):
#   1) 이 파일을 VM /opt/scatchlm/scripts/backup_db.sh 로 복사하고 chmod +x.
#   2) crontab -e 에 일 1회 등록 (예: 매일 03:17 KST):
#        17 3 * * * /opt/scatchlm/scripts/backup_db.sh >> /var/log/scatchlm-backup.log 2>&1
#
# 수동 1회 실행: bash /opt/scatchlm/scripts/backup_db.sh
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/scatchlm}"
COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env.prod"
DATE="$(date +%F)"                       # YYYY-MM-DD
KEY="backups/db/scatchlm-${DATE}.dump"
DB="${POSTGRES_DB:-scatchlm}"
PGUSER="${POSTGRES_USER:-postgres}"

cd "$STACK_DIR"

echo "[backup] $(date -Is) start → s3://.../${KEY}"

# pg_dump(postgres 컨테이너) | upload_stream(app 컨테이너, boto3). 임시파일 없음.
# pipefail 켜져 있어 pg_dump 실패도 전체 실패로 전파된다.
if $COMPOSE exec -T postgres pg_dump -U "$PGUSER" -Fc "$DB" \
   | $COMPOSE exec -T app python3 /app/scripts/upload_stream.py "$KEY"; then
    echo "[backup] $(date -Is) OK → ${KEY}"
else
    rc=$?
    echo "[backup] $(date -Is) FAILED rc=${rc} key=${KEY}" >&2
    # 실패가 조용하면 백업 부재와 동일(텔레메트리 사각지대 교훈). 알림 훅이 있으면 호출.
    if [ -n "${BACKUP_ALERT_CMD:-}" ]; then
        eval "$BACKUP_ALERT_CMD" || true
    fi
    exit "$rc"
fi
