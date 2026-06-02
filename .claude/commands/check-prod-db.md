# /check-prod-db - 운영(NCP VM) DB 직접 조회

`https://scatchlm.duckdns.org` (NCP VM)에서 돌아가는 프로덕션 PostgreSQL(pgvector)을 SSH 경유로 조회한다.

## 접근 경로 (이것밖에 없음)

프로덕션 postgres는 **외부 노출이 전혀 안 됨**. `docker-compose.prod.yml`의 postgres 서비스에 `ports:` 매핑이 없어서 VM의 5432는 바깥으로 안 열린다 (같은 도커 네트워크의 `app` 컨테이너만 `postgres:5432`로 접속). ACG도 22/80/443만 허용.

따라서 로컬에서 `psql -h scatchlm.duckdns.org` 같은 직접 TCP 접속은 **불가능**하고, 유일한 진입점은:

```
[내 맥]  --ssh-->  [NCP VM]  --docker compose exec-->  [postgres 컨테이너]  --psql-->  scatchlm DB
```

- SSH alias: `scatchlm` (`~/.ssh/config`에 등록, User=root, HostName=scatchlm.duckdns.org)
- 컨테이너: `scatchlm-prod-postgres-1` (서비스명 `postgres`), 이미지 `pgvector/pgvector:pg17`
- 자격증명: `/opt/scatchlm/.env.prod`의 `POSTGRES_USER`(기본 postgres) / `POSTGRES_PASSWORD` / `POSTGRES_DB`(기본 scatchlm)
- DB 안에선 user `postgres` / db `scatchlm` (컨테이너 내부 psql은 비밀번호 불필요 — local peer/trust)

베이스 명령:
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c "<SQL>"'
```

> - `--env-file .env.prod` 필수. 빼면 `APP_IMAGE`/`DOMAIN` 미해석으로 compose 명령 거부됨.
> - `exec -T` 필수 (비대화형, TTY 할당 안 함). 빼면 SSH 비-TTY 환경에서 에러.

## 사용법

```
/check-prod-db                          # 테이블 목록 + 주요 테이블 row 수 요약
/check-prod-db SELECT count(*) FROM users;   # 임의 SQL 실행
/check-prod-db tables                   # \dt
/check-prod-db schema users             # users 테이블 스키마 (\d users)
/check-prod-db psql                     # 대화형 psql 셸 접속 명령 안내 (직접 실행은 사용자가)
/check-prod-db backup                   # pg_dump 백업 (로컬로 gzip 저장)
```

## 자주 쓰는 패턴

### 테이블 목록
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c "\dt"'
```

### 임의 SQL (읽기)
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c "SELECT id, email, tier FROM users ORDER BY created_at DESC LIMIT 20;"'
```

### 테이블 스키마
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c "\d feedbacks"'
```

### 주요 테이블 row 수 한눈에
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"'
```

### 현재 마이그레이션 버전
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c "SELECT version_num FROM alembic_version;"'
```

### 대화형 psql 셸 (사용자가 직접 실행)
이 명령은 TTY가 필요하므로 Claude가 대신 실행하지 말고 사용자에게 안내한다:
```bash
ssh -t scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec postgres psql -U postgres -d scatchlm'
```

### 백업 (pg_dump → 로컬 저장)
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres pg_dump -U postgres scatchlm' | gzip > "prod-backup-$(date +%F).sql.gz"
```

## Arguments

- `$ARGUMENTS`: SQL 문 또는 옵션
  - 비어있음 → 테이블별 row 수 요약
  - `tables` → `\dt`
  - `schema <table>` → `\d <table>`
  - `psql` → 대화형 셸 접속 명령을 출력만 (사용자 직접 실행)
  - `backup` → pg_dump 백업
  - 그 외 → SQL 문으로 간주하고 실행

## 안전 수칙 (회의주의 시니어 모드)

- **쓰기/DDL(UPDATE/DELETE/DROP/ALTER 등)은 사용자 명시 승인 없이는 실행하지 않는다.** 프로덕션 데이터다.
- 파괴적 쿼리 전엔 영향 범위(예상 row 수)를 SELECT로 먼저 확인하고 보고한 뒤 승인받는다.
- 대량 SELECT는 `LIMIT`을 붙여 조회한다.
- 결과에 PII(email 등)가 포함될 수 있으니 외부로 붙여넣지 않는다.

## 실행 로직

```bash
PSQL="ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm"

if [ -z "$ARGUMENTS" ]; then
  eval "$PSQL -c \"SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;\"'"
elif [ "$ARGUMENTS" = "tables" ]; then
  eval "$PSQL -c \"\\dt\"'"
elif echo "$ARGUMENTS" | grep -q "^schema "; then
  tbl=$(echo "$ARGUMENTS" | sed 's/^schema //')
  eval "$PSQL -c \"\\d $tbl\"'"
elif [ "$ARGUMENTS" = "psql" ]; then
  echo "대화형 셸은 직접 실행하세요:"
  echo "ssh -t scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec postgres psql -U postgres -d scatchlm'"
elif [ "$ARGUMENTS" = "backup" ]; then
  ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres pg_dump -U postgres scatchlm' | gzip > "prod-backup-$(date +%F).sql.gz"
  echo "저장됨: prod-backup-$(date +%F).sql.gz"
else
  # SQL 문으로 간주. 쓰기/DDL이면 승인 먼저.
  eval "$PSQL -c \"$ARGUMENTS\"'"
fi
```
