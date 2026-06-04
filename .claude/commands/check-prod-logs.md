# /check-prod-logs - 운영(NCP VM) 백엔드 로그 확인

`https://scatchlm.duckdns.org` (NCP VM)에서 돌아가는 docker compose 스택의 로그를 SSH로 가져온다.

스택 구성:
- `app` — FastAPI/uvicorn (Anthropic, Voyage, Supabase, Object Storage 호출 + iOS FE 로그 수신)
- `postgres` — pgvector
- `caddy` — 리버스 프록시 + Let's Encrypt

기본 대상은 `app`. 다른 서비스(`postgres`, `caddy`)는 `service=` 접두어로 지정.

## 사용법

```
/check-prod-logs                  # 최근 50줄 (app 서비스)
/check-prod-logs feedback         # "feedback" 필터
/check-prod-logs FE               # iOS 앱에서 보낸 FE 로그
/check-prod-logs error            # 에러만
/check-prod-logs service=caddy    # Caddy 로그 (인증서/접근 로그)
/check-prod-logs service=postgres # Postgres 로그
/check-prod-logs follow           # 실시간 스트림 (Ctrl+C로 중단)
/check-prod-logs users            # 최근 24h 사용자 수·세션·액션 통계 (별칭: stats)
/check-prod-logs users 48h        # 윈도우 지정 (기본 24h)
```

## 로그 가져오기 (단일 호스트)

VM은 SSH alias `scatchlm`로 접속한다. `~/.ssh/config`에 등록돼 있음 (User: root, HostName: scatchlm.duckdns.org).

베이스 명령:
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=200 app'
```

> `--env-file .env.prod` 필수. 빼면 `APP_IMAGE`/`DOMAIN` 미해석 에러로 명령 실패.

## 자주 쓰는 패턴

### 전체 최근 로그
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=50 app' | grep -v "GET /docs"
```

### FE (iOS 앱) 로그
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=500 app' | grep -i "FE\|\[fe\]" | tail -30
```

### 에러
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=1000 app' | grep -iE "error|exception|traceback|failed" | tail -30
```

### 피드백/채팅
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=500 app' | grep -iE "feedback|chat response|LLM response" | tail -20
```

### RAG / 검색
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=500 app' | grep -iE "RAG|Query rewrite|Chapter search|Page search" | tail -20
```

### PDF / Object Storage
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=500 app' | grep -iE "pdf|s3|storage|object" | tail -20
```

### Caddy (인증서/접근)
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --tail=100 caddy' | tail -30
```

### 사용자 활동 분석 (`users` / `stats`) — SQL 집계 (app_logs)

> **2026-06-04 전환(data-durability-spec §B.4 Track B):** FE 텔레메트리가 `app_logs` 테이블에
> 영속 적재되므로 **활동 집계는 grep이 아니라 SQL**이다. `app_logs`는 배포(컨테이너 재생성)에
> 살아남고, `user_id`/`session_id`를 **절단 없이 전체값**으로 저장해 `users`와 equi-join한다
> (prefix LIKE 우회 불필요). 윈도우 경계도 컨테이너 재시작과 무관 — DB ts 기준.
>
> **이원화:** 활동 집계 = SQL(아래). **라이브 tail(`follow`)·단발 키워드 grep·백엔드
> `[access]` API 호출 집계는 여전히 json-log grep**(아래 "백엔드 [access]는 grep 유지" 참고).
> `[access]`는 `_emit`을 안 거쳐 `app_logs`에 없다(§B.5 한계).

모든 쿼리는 `/check-prod-db` 경로(SSH → docker compose exec postgres psql)로 실행한다.
윈도우(`users 48h`)는 `interval` 값으로 치환한다(기본 `24 hours`).

```bash
WIN="24 hours"   # users 뒤 인자(예: 48h → '48 hours'), 기본 24h
PSQL() { ssh scatchlm "cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c \"$1\""; }
```

```bash
# 1) 고유 사용자 + 이메일 + 로그량 + 세션수 + 활동 구간 (핵심 표)
PSQL "SELECT l.user_id, u.email, count(*) AS log_count,
       count(DISTINCT l.session_id) AS sessions,
       min(l.ts) AS first_seen, max(l.ts) AS last_seen
FROM app_logs l LEFT JOIN users u ON u.id = l.user_id
WHERE l.ts > now() - interval '$WIN'
GROUP BY l.user_id, u.email ORDER BY log_count DESC;"

# 2) 액션 태그 빈도 (FE)
PSQL "SELECT tag, count(*) FROM app_logs
WHERE ts > now() - interval '$WIN' AND tag <> ''
GROUP BY tag ORDER BY count DESC LIMIT 40;"

# 3) uxTrack 결과 분포 (ok/cancel/fail 등)
PSQL "SELECT data->>'result' AS result, count(*) FROM app_logs
WHERE ts > now() - interval '$WIN' AND tag IN ('ux','uxError')
GROUP BY 1 ORDER BY 2 DESC;"

# 4) 에러
PSQL "SELECT ts, user_id, tag, message FROM app_logs
WHERE ts > now() - interval '$WIN' AND level = 'error'
ORDER BY ts DESC LIMIT 30;"
```

> - **`LEFT JOIN`이라 `email IS NULL`인 row = 로그엔 있으나 `users`에 없는 user_id**
>   (가입 실패/삭제) — grep 시절 "미가입 prefix" 수기 판정을 SQL이 흡수한다. 보고 시 명시.
> - **prefix→이메일 자동 JOIN 단계 불필요**: 전체값 저장이라 `u.id = l.user_id` equi-join.
> - 사용자별 상세: 위 쿼리에 `AND l.user_id = '<full-uuid>'`를 붙이거나 태그별로 `GROUP BY tag`.

**백엔드 `[access]` API 호출 집계는 grep 유지** (app_logs에 없음 — §B.5):
```bash
ssh scatchlm "cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --since 24h app" 2>/dev/null \
  | grep -E '\[access\]' | grep -oE '(GET|POST|PUT|DELETE) /api/[a-zA-Z0-9/_-]+' \
  | grep -v '/api/dev/log/batch' | sort | uniq -c | sort -rn | head -30
```

> 결과 보고 시: 고유 유저 수(+이메일 매칭), 세션 수, 시간 범위, 상위 액션 태그, (grep) 상위 API,
> 에러 요약, uxTrack 결과 분포를 표로 정리. 매칭 실패(`email IS NULL`)는 "미가입/삭제"로 명시.
> **이메일은 PII이므로 결과를 외부(이슈/PR/채팅 등)에 붙여넣지 않는다.**

### 실시간 스트림 (follow)
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f --no-color --tail=20 app'
```
> 백그라운드로 띄울 때만 사용. Bash run_in_background=true 권장. 직접 터미널에서 보고 싶으면 그대로 ssh 명령을 사용자에게 안내.

## Arguments

- `$ARGUMENTS`: 필터 키워드 또는 옵션
  - 비어있음 → app 서비스 최근 50줄
  - `follow` → 실시간 스트림
  - `service=<name>` → 해당 서비스 로그
  - `users` / `stats` (+ 선택 윈도우, 예: `users 48h`) → 사용자 활동 분석 (위 섹션). 등장한
    user prefix를 `users` 테이블과 자동 join해 이메일까지 매칭(미가입/삭제 prefix는 명시)
  - 그 외 → 키워드 grep

## 실행 로직

```bash
SSH_BASE="ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color"

if [ -z "$ARGUMENTS" ]; then
  eval "$SSH_BASE --tail=50 app'" | grep -v "GET /docs"
elif [ "$ARGUMENTS" = "follow" ]; then
  eval "$SSH_BASE -f --tail=20 app'"
elif echo "$ARGUMENTS" | grep -qE "^(users|stats)( |$)"; then
  # 사용자 활동 분석 — "사용자 활동 분석" 섹션의 SQL 집계(app_logs)를 따른다.
  # 윈도우는 두 번째 토큰(예: "users 48h" → '48 hours'), 없으면 '24 hours'.
  W=$(echo "$ARGUMENTS" | awk '{print $2}'); W=${W:-24h}
  WIN="${W%h} hours"   # "48h" → "48 hours"
  # → 위 섹션의 PSQL 쿼리들을 interval '$WIN'로 실행. [access] 집계만 json-log grep 유지.
elif echo "$ARGUMENTS" | grep -q "^service="; then
  svc=$(echo "$ARGUMENTS" | sed 's/^service=//')
  eval "$SSH_BASE --tail=100 $svc'"
else
  eval "$SSH_BASE --tail=500 app'" | grep -i "$ARGUMENTS" | tail -30
fi
```

## 운영 상태 점검 (덤)

```bash
# 컨테이너 상태
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod ps'

# 디스크 사용량
ssh scatchlm 'df -h / && docker system df'

# 외부 헬스체크
curl -sS -o /dev/null -w "HTTPS %{http_code}\n" https://scatchlm.duckdns.org/docs
```
