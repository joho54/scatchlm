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

### 사용자 활동 분석 (`users` / `stats`)

FE 로그의 `[u:<id>]`(유저 prefix)·`[sess:<id>]`(세션)·`[tag]`(액션) 토큰을 집계해
"최근 N시간 동안 누가 / 몇 명이 / 무엇을 했나"를 통계로 낸다. **prefix 폭(8/12)에
무관하게** `[0-9a-f]+`로 매칭하므로 백엔드 절단폭이 바뀌어도 그대로 동작한다.

먼저 윈도우만큼 로그를 파일로 저장(여러 번 grep하므로 1회만 fetch):
```bash
WIN=24h   # users 뒤 인자로 받은 값, 기본 24h
ssh scatchlm "cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --since $WIN app" 2>/dev/null > /tmp/prodlogs_users.txt
echo "수집: $(wc -l < /tmp/prodlogs_users.txt) 줄 / 범위: $(grep -oE '2026-[0-9-]+ [0-9:]+' /tmp/prodlogs_users.txt | head -1) ~ $(grep -oE '2026-[0-9-]+ [0-9:]+' /tmp/prodlogs_users.txt | tail -1)"
```
> ⚠️ `--since`는 **컨테이너 재시작 이후**만 보장된다(재시작 시 이전 로그 유실). 범위 출력의
> 시작 시각이 요청 윈도우보다 늦으면 그 사이 app이 재시작된 것 — 그 한계를 사용자에게 알린다.

집계:
```bash
cd /tmp
echo "===== 고유 사용자 (로그량 순) ====="
grep -oE '\[u:[0-9a-f]+\]' prodlogs_users.txt | sort | uniq -c | sort -rn

echo "===== 세션 → 사용자 매핑 ====="
grep -oE '\[sess:[0-9A-F]+\] \[u:[0-9a-f]+\]' prodlogs_users.txt | sort | uniq -c | sort -rn

echo "===== 핵심 백엔드 API 호출 (로그 배치 제외) ====="
grep -E '\[access\]' prodlogs_users.txt | grep -oE '(GET|POST|PUT|DELETE) /api/[a-zA-Z0-9/_-]+' \
  | grep -v '/api/dev/log/batch' | sort | uniq -c | sort -rn | head -30

echo "===== 액션 태그 빈도 (FE) ====="
grep -oE '\[u:[0-9a-f]+\] \[[a-z]+\] [a-zA-Z][a-zA-Z0-9 :=_-]*' prodlogs_users.txt \
  | sed -E 's/\[u:[0-9a-f]+\] //' | sort | uniq -c | sort -rn | head -40

echo "===== uxTrack 인증/액션 결과 (ok/cancel/fail) ====="
grep -oE '\[ux(Error)?\] [a-z.]+ (ok|cancel|fail)' prodlogs_users.txt | sort | uniq -c | sort -rn
```

사용자별 상세(특정 유저만):
```bash
U=66d2d3d1   # 분석할 유저 prefix
grep "\[u:$U" /tmp/prodlogs_users.txt | grep -oE '\[[a-z]+\] [a-zA-Z][a-zA-Z0-9 :=_-]*' \
  | sort | uniq -c | sort -rn | head -25
```

에러/실패:
```bash
grep -iE 'error|exception|traceback|-> [45][0-9][0-9]|performSync failed| fail ' /tmp/prodlogs_users.txt \
  | grep -ivE 'Sentry disabled' | tail -30
```

**prefix → 실제 계정 식별(자동 DB join):** 로그는 가명(UUID prefix)뿐이라 이메일은 `users`
테이블 join이 필요하다. `users`/`stats` 분석 시 **이 단계를 항상 함께 수행**해 prefix에
이메일을 붙인다. 로그에서 등장한 prefix 전부를 한 번에 모아 단일 쿼리로 조회한다(유저당
쿼리 X). prefix 폭(8/12)에 무관하게 `id::text`의 좌측 일치로 매칭한다.

```bash
# 로그에서 등장한 고유 user prefix 추출 → '|'로 묶어 OR 정규식 생성
PREFIXES=$(grep -oE '\[u:[0-9a-f]+\]' /tmp/prodlogs_users.txt \
  | sed -E 's/\[u:([0-9a-f]+)\]/\1/' | sort -u | paste -sd'|' -)
echo "조회 대상 prefix: $PREFIXES"

# 단일 쿼리로 매칭 (id 텍스트가 어떤 prefix로 시작하는지). 결과는 PII이므로 외부 유출 금지.
ssh scatchlm "cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T postgres psql -U postgres -d scatchlm -c \"SELECT left(id::text,12) AS prefix, email, created_at FROM users WHERE id::text ~ '^($PREFIXES)' ORDER BY created_at;\""
```

> - `id::text ~ '^(p1|p2|...)'` 는 prefix 어느 하나로 시작하는 row만 반환 — 로그에 없는
>   유저는 제외된다.
> - **매칭 안 되는 prefix 주의**: 로그엔 있는데 결과에 없으면 = 가입 실패(회원가입 전
>   인증 단계 이탈) 또는 계정 삭제. 위 Apple sign-in 실패 케이스(`66d2d3d1`)가 전형적 —
>   이때는 "DB row 없음 = 미가입"으로 보고한다.
> - 직접 `/check-prod-db`를 거쳐도 되지만, 위처럼 로그 fetch와 같은 흐름에서 자동 join하는
>   것을 기본으로 한다.

> 결과 보고 시: 고유 유저 수(+이메일 매칭), 세션 수, 시간 범위, 상위 액션/API, 에러 요약,
> (있으면) uxTrack ok/cancel/fail 분포를 표로 정리. 사용자 표에는 prefix·이메일·로그량·
> 세션수를 함께 싣고, 매칭 실패 prefix는 "미가입/삭제"로 명시한다. **이메일은 PII이므로
> 결과를 외부(이슈/PR/채팅 등)에 붙여넣지 않는다.**

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
  # 사용자 활동 분석 — "사용자 활동 분석" 섹션의 절차를 따른다.
  # 윈도우는 두 번째 토큰(예: "users 48h"), 없으면 24h.
  WIN=$(echo "$ARGUMENTS" | awk '{print $2}'); WIN=${WIN:-24h}
  ssh scatchlm "cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color --since $WIN app" 2>/dev/null > /tmp/prodlogs_users.txt
  # → 이후 위 섹션의 집계 grep들을 /tmp/prodlogs_users.txt에 대해 실행
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
