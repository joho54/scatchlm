# 백업 사이드카 — Postgres 논리 백업 + app_logs prune을 host cron이 아니라 compose 서비스로.
#
# data-durability-spec §A.3/§B.4를 컨테이너로 이관한다. 이유: host root crontab은 박스
# 재생성 때 따라오지 않아 2026-06-18에 백업이 7일간 조용히 죽었다(원인 규명됨). compose
# 서비스는 git-managed(deploy가 docker-compose.prod.yml을 scp 동기화)라 박스가 갈려도
# `up -d`로 되살아난다 — 스케줄러를 app과 동일한 단일 lifecycle/출처로 합쳐 실패 클래스 제거.
#
# 베이스를 postgres:17로 두는 이유: pg_dump를 **서버와 동일 메이저(17)**로 고정. 구버전
# pg_dump는 상위 서버 덤프를 거부하므로 버전 드리프트를 원천 차단. psql(prune)도 포함.
FROM postgres:17-bookworm

# 업로더(boto3)·스케줄러(supercronic)·tz 데이터. pg_dump/psql은 베이스에 이미 있음.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-boto3 ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/*

# supercronic: 컨테이너용 cron. vixie-cron과 달리 컨테이너 환경변수를 잡에 그대로 전달하고
# (OBJECT_STORAGE_*/POSTGRES_* 주입 필수) 로그를 stdout으로 내보낸다(docker compose logs 관측).
ARG SUPERCRONIC_VERSION=v0.2.33
RUN curl -fsSL -o /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    && chmod +x /usr/local/bin/supercronic

# 업로더는 app과 동일 스크립트 재사용(중복 0). 백업/prune 러너와 crontab만 신규.
COPY scripts/upload_stream.py /usr/local/bin/upload_stream.py
COPY backup/run_backup.sh    /usr/local/bin/run_backup.sh
COPY backup/run_prune.sh     /usr/local/bin/run_prune.sh
COPY backup/crontab          /etc/supercronic/crontab
RUN chmod +x /usr/local/bin/run_backup.sh /usr/local/bin/run_prune.sh

# postgres 베이스의 ENTRYPOINT(docker-entrypoint.sh)는 DB를 띄우려 한다 — 우회하고 스케줄러만 실행.
# -no-reap: supercronic의 프로세스 reaper를 끈다. 이 런타임(Docker 29 / 커널 6.8)에서 reaper
#   초기화가 "Failed to fork exec"로 fatal → 크래시루프였다(-no-reap 없이는 crontab 파싱도 못 감).
#   백업 잡은 단발성(pg_dump|upload)이라 고아 프로세스 회수가 불필요하므로 끄는 게 안전.
ENTRYPOINT []
CMD ["supercronic", "-no-reap", "/etc/supercronic/crontab"]
