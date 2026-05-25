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
  - 그 외 → 키워드 grep

## 실행 로직

```bash
SSH_BASE="ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color"

if [ -z "$ARGUMENTS" ]; then
  eval "$SSH_BASE --tail=50 app'" | grep -v "GET /docs"
elif [ "$ARGUMENTS" = "follow" ]; then
  eval "$SSH_BASE -f --tail=20 app'"
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
