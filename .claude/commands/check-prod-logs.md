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

**prefix → 실제 계정 식별(트리아지):** 로그는 가명(UUID prefix)뿐이라 이메일은 DB join 필요.
`/check-prod-db`로:
```sql
SELECT id, email, created_at FROM users WHERE id LIKE '66d2d3d1%';
```
> 결과 보고 시: 고유 유저 수, 세션 수, 시간 범위, 상위 액션/API, 에러 요약, (있으면) uxTrack
> ok/cancel/fail 분포를 표로 정리. 식별이 필요하면 prefix를 뽑아 DB join을 안내/수행.

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
  - `users` / `stats` (+ 선택 윈도우, 예: `users 48h`) → 사용자 활동 분석 (위 섹션)
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
