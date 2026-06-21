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
/check-prod-logs swap             # 스왑 점유/활동(si·so)·컨테이너별 스왑 스냅샷 (Micro 1GB RAM)
/check-prod-logs swap watch       # 스왑 활동 실시간 (vmstat 1) — thrash 감시, Ctrl+C로 중단
/check-prod-logs users            # 최근 24h 사용자 수·세션·액션 통계 (별칭: stats)
/check-prod-logs users 48h        # 윈도우 지정 (기본 24h)
/check-prod-logs funnel           # 활성화 퍼널 + 리텐션 (별칭: cohort, 기본 30d)
/check-prod-logs funnel 7d        # 활성화 윈도우 지정 (리텐션은 전체 기간 코호트)
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

### 활성화·리텐션 분석 (`funnel` / `cohort`) — SQL 집계 (app_logs)

광고(ASA) 켜기 전후로 "유입된 유저가 *첫 성공 피드백*까지 가나(활성화), 다시 오나(리텐션)"를
바로 통계화. 새 계측 불필요 — 이미 적재된 FE 이벤트(`appLog` info, Release 유저도 옴)로 SQL만.

마일스톤 정의 (message 기준):
- **signed in** = `user_id` 존재 (앱 진입 + 인증)
- **created note** = `createNote OK`
- **uploaded textbook** = `upload OK` (실패는 `upload failed`)
- **activated** = `feedback received` (성공). cf. `feedback: no new strokes` = 눌렀으나 빈 캔버스

`PSQL`/`WIN`은 위 "사용자 활동 분석" 섹션 정의 재사용. 활성화 윈도우 기본 `30 days`(짧으면 신규가
마일스톤 도달 전이라 과소집계). **리텐션 D1/D7은 코호트라 윈도우 무시하고 전체 기간** 사용.

```bash
# A) 활성화 퍼널 — 윈도우 내 고유 유저의 단계별 도달 수 (NULL user_id=pre-auth 제외)
PSQL "SELECT
  count(DISTINCT user_id) AS users,
  count(DISTINCT user_id) FILTER (WHERE message='createNote OK')   AS created_note,
  count(DISTINCT user_id) FILTER (WHERE message='upload OK')        AS uploaded_tb,
  count(DISTINCT user_id) FILTER (WHERE message='feedback received') AS activated
FROM app_logs WHERE user_id IS NOT NULL AND ts > now() - interval '$WIN';"

# B) 유저별 마일스톤 + 활동일수 (소표본 eyeball용; 내부 계정은 해석 시 제외)
PSQL "SELECT u.email, min(l.ts)::date AS first_day,
  count(DISTINCT l.ts::date) AS active_days,
  bool_or(l.message='createNote OK')    AS made_note,
  bool_or(l.message='upload OK')         AS uploaded,
  bool_or(l.message='feedback received') AS activated
FROM app_logs l LEFT JOIN users u ON u.id=l.user_id
WHERE l.user_id IS NOT NULL AND l.ts > now() - interval '$WIN'
GROUP BY u.email ORDER BY first_day;"

# C) 리텐션 — 전체 기간 코호트(윈도우 무시). 첫 활동일(d0) 대비 복귀.
PSQL "WITH f AS (SELECT user_id, min(ts)::date AS d0 FROM app_logs
                 WHERE user_id IS NOT NULL GROUP BY user_id),
           d AS (SELECT DISTINCT user_id, ts::date AS day FROM app_logs WHERE user_id IS NOT NULL)
SELECT count(DISTINCT f.user_id) AS users,
  count(DISTINCT f.user_id) FILTER (WHERE d.day > f.d0)                         AS returned_any,
  count(DISTINCT f.user_id) FILTER (WHERE d.day = f.d0 + 1)                     AS d1,
  count(DISTINCT f.user_id) FILTER (WHERE d.day > f.d0 AND d.day <= f.d0 + 7)   AS within_7d
FROM f LEFT JOIN d ON d.user_id=f.user_id;"

# D) 설치일(첫활동일) 코호트 — ASA 어트리뷰션 프록시. 광고 켠 날 전후 신규/활성화 비교.
PSQL "WITH f AS (SELECT l.user_id, min(l.ts)::date AS d0,
                        bool_or(l.message='feedback received') AS activated
                 FROM app_logs l WHERE l.user_id IS NOT NULL GROUP BY l.user_id)
SELECT d0 AS cohort_day, count(*) AS new_users,
       count(*) FILTER (WHERE activated) AS activated
FROM f GROUP BY d0 ORDER BY d0;"
```

#### 코어 루프 안정성 (구조화 `funnel` 태그 — step/result/reason/ms)

> **2026-06-09 추가(funnel-stability-telemetry-spec):** 위 A~D는 *활성화 도달*(성공만)을 본다.
> 아래 E~G는 **step별 실패율·원인·지연**을 본다 — 방향1(안정화) 우선순위를 데이터로 정렬하는 뷰.
> 소스는 `tag='funnel'`, `data`의 `step`(appOpen/onboarding*/noteCreate/textbookUpload/feedback/sync),
> `result`(start/ok/fail/empty/cancel), `reason`(http_4xx/5xx/422·offline·timeout·quota·decode·…), `ms`.
> message 문자열이 아니라 `data` 필드 집계라 문구 변경에 안 깨짐. (sync는 폴링 플러딩 회피로 `fail`만 적재.)

```bash
# E) 코어 루프 step별 시도/성공/실패율 + 지연 (안정성 단일 뷰) ★핵심
PSQL "SELECT data->>'step' AS step,
  count(*) FILTER (WHERE data->>'result'='start') AS attempts,
  count(*) FILTER (WHERE data->>'result'='ok')    AS ok,
  count(*) FILTER (WHERE data->>'result'='fail')  AS fail,
  round(100.0*count(*) FILTER (WHERE data->>'result'='fail')
        / NULLIF(count(*) FILTER (WHERE data->>'result' IN ('ok','fail')),0),1) AS fail_pct,
  percentile_disc(0.5)  WITHIN GROUP (ORDER BY (data->>'ms')::int) FILTER (WHERE data->>'ms' IS NOT NULL) AS p50_ms,
  percentile_disc(0.95) WITHIN GROUP (ORDER BY (data->>'ms')::int) FILTER (WHERE data->>'ms' IS NOT NULL) AS p95_ms
FROM app_logs WHERE tag='funnel' AND ts > now() - interval '$WIN'
GROUP BY 1 ORDER BY fail DESC;"

# F) 실패 원인 분포 — 어디가 왜 깨지나 (트리아지)
PSQL "SELECT data->>'step' AS step, data->>'reason' AS reason, count(*)
FROM app_logs WHERE tag='funnel' AND data->>'result'='fail' AND ts > now()-interval '$WIN'
GROUP BY 1,2 ORDER BY 3 DESC;"

# G) 온보딩 드롭오프 — session 단위 (pre-auth 포함, welcome→시작→마치기)
PSQL "SELECT
  count(DISTINCT session_id) FILTER (WHERE data->>'step'='onboardingShown')  AS shown,
  count(DISTINCT session_id) FILTER (WHERE data->>'step'='onboardingStart')  AS started,
  count(DISTINCT session_id) FILTER (WHERE data->>'step'='onboardingSkip')    AS skipped,
  count(DISTINCT session_id) FILTER (WHERE data->>'step'='onboardingFinish') AS finished
FROM app_logs WHERE tag='funnel' AND ts > now()-interval '$WIN';"
```

> E~G 한계: app 진입 이후만(pre-auth top-of-funnel은 ASA). `unknown` reason 비중이 크면 E의
> 분류 버킷(`reasonClass`/`APIError.reasonTag`)에 case 추가. sync는 `fail`만이라 E에서 fail_pct=NULL.

> **한계 (A~D, 보고 시 명시):**
> - **pre-auth(설치→가입 전 이탈)는 안 보임** — `user_id` 기준이라. top-of-funnel(노출·탭·설치)은
>   **ASA 대시보드**가 단일 진실. app_logs는 "앱 진입 이후"만.
> - **어트리뷰션 없음** — 어떤 설치가 광고发인지 app_logs는 모름. D) 설치일 코호트로 "광고 켠 주
>   신규 활성화율 vs 안 켠 주"를 **프록시 비교**만 가능. 정밀 귀속은 Apple Ads Attribution(AdServices).
> - **내부 계정 오염** — 개발자 본인 계정(gmail/naver/hufs 등)이 퍼널·리텐션을 부풀린다. B) 표로
>   eyeball하거나 쿼리에 `AND u.email NOT IN ('joho0504@gmail.com', …)` 추가해 제외하고 해석.
> - **마일스톤은 message 문자열 의존** — FE 로그 메시지가 바뀌면 쿼리도 갱신 필요.
> - **app_logs는 2026-06-04부터 적재** — 그 이전 활동 유저는 퍼널/리텐션에 **안 보이고**(예:
>   textbook_sources엔 있으나 app_logs엔 없는 유저), 06-04 걸친 유저의 `d0`가 **06-04로 clamp**되어
>   설치일 코호트(D)가 왜곡된다. 06-04 직후 구간은 "진짜 신규"가 아닐 수 있으니 해석 주의.

### 스왑 모니터링 (`swap`) — Micro 1GB RAM 안정성

> Micro(1 vCPU/1GB)는 RAM이 빠듯해 swap이 OOM 안전판이다(§DEPLOY.md). 봐야 할 건 **점유량**이
> 아니라 **활동률**이다: swap에 cold page가 *주차*된 건 무해, 페이지가 계속 오가는 *thrash*가
> 위험(디스크 I/O로 지연·디스크 마모). `vmstat`의 `si`/`so`(초당 swap-in/out KB)가 0이면 무활동,
> 지속적으로 >0이면 thrash 신호. `sysstat`(sar) 설치돼 있어 과거 이력도 가능.

**스냅샷 (`swap`)** — 점유 + 짧은 활동 샘플 + 컨테이너별 분해:
```bash
ssh scatchlm 'echo "=== free ==="; free -h
echo "=== vmstat 5x1s (si/so = 초당 swap-in/out KB; 첫 행은 부팅평균이라 무시) ==="; vmstat 1 5
echo "=== 누적 swap 페이지 (pswpin/pswpout, 부팅 이후) ==="; grep -E "pswpin|pswpout" /proc/vmstat
echo "=== 컨테이너별 swap 사용 (cgroup v2) ==="
for c in $(docker ps --format "{{.Names}}"); do
  id=$(docker inspect -f "{{.Id}}" "$c")
  f=$(find /sys/fs/cgroup -name memory.swap.current -path "*$id*" 2>/dev/null | head -1)
  [ -n "$f" ] && printf "%-28s %s bytes\n" "$c" "$(cat "$f")"
done'
```

**과거 이력 (sar)** — 분 단위 swap-in/out·메모리 압력:
```bash
ssh scatchlm 'echo "=== sar -W (swap 페이지 in/out 이력) ==="; sar -W
echo "=== sar -S (swap 공간 사용률 이력) ==="; sar -S'
```

**실시간 감시 (`swap watch`)** — thrash 의심 시 라이브로 si/so 관찰:
```bash
ssh scatchlm 'vmstat 1'
```
> 백그라운드(run_in_background=true)로 띄우고 si/so가 지속적으로 >0인지 본다. 0 근처면 정상.

> **해석 가이드**: `Swap used` 높음 + `si`/`so` ≈ 0 → cold page 주차, **정상**. `si`/`so` 지속 >0 +
> `Mem available` 낮음 → 메모리 압력으로 thrash, **위험 신호**(swappiness 조정/스왑 증설/Standard
> 재마이그레이션 검토). `memory.events`의 `oom`/`oom_kill` 증가 = 이미 OOM kill 발생(컨테이너별).

### 실시간 스트림 (follow)
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f --no-color --tail=20 app'
```
> 백그라운드로 띄울 때만 사용. Bash run_in_background=true 권장. 직접 터미널에서 보고 싶으면 그대로 ssh 명령을 사용자에게 안내.

## Arguments

- `$ARGUMENTS`: 필터 키워드 또는 옵션
  - 비어있음 → app 서비스 최근 50줄
  - `follow` → 실시간 스트림
  - `swap` (+ 선택 `watch`) → 스왑 모니터링 (위 섹션). `swap`=스냅샷, `swap watch`=vmstat 1 라이브
  - `service=<name>` → 해당 서비스 로그
  - `users` / `stats` (+ 선택 윈도우, 예: `users 48h`) → 사용자 활동 분석 (위 섹션). 등장한
    user prefix를 `users` 테이블과 자동 join해 이메일까지 매칭(미가입/삭제 prefix는 명시)
  - `funnel` / `cohort` (+ 선택 윈도우, 예: `funnel 7d`) → 활성화 퍼널 + 리텐션 (위 섹션).
    활성화 윈도우 기본 30d, 리텐션은 전체 기간 코호트. 한계(pre-auth·어트리뷰션·내부계정) 명시
  - 그 외 → 키워드 grep

## 실행 로직

```bash
SSH_BASE="ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod logs --no-color"

if [ -z "$ARGUMENTS" ]; then
  eval "$SSH_BASE --tail=50 app'" | grep -v "GET /docs"
elif [ "$ARGUMENTS" = "follow" ]; then
  eval "$SSH_BASE -f --tail=20 app'"
elif echo "$ARGUMENTS" | grep -qE "^swap( |$)"; then
  # 스왑 모니터링 — "스왑 모니터링" 섹션 참조. "swap watch"면 vmstat 1 라이브(run_in_background),
  # 그냥 "swap"이면 free+vmstat 5x1s+pswpin/out+컨테이너별 cgroup 스냅샷.
  if echo "$ARGUMENTS" | grep -q "watch"; then
    ssh scatchlm 'vmstat 1'   # run_in_background 권장
  else
    : # → 위 "스냅샷 (swap)" 블록 실행
  fi
elif echo "$ARGUMENTS" | grep -qE "^(users|stats)( |$)"; then
  # 사용자 활동 분석 — "사용자 활동 분석" 섹션의 SQL 집계(app_logs)를 따른다.
  # 윈도우는 두 번째 토큰(예: "users 48h" → '48 hours'), 없으면 '24 hours'.
  W=$(echo "$ARGUMENTS" | awk '{print $2}'); W=${W:-24h}
  WIN="${W%h} hours"   # "48h" → "48 hours"
  # → 위 섹션의 PSQL 쿼리들을 interval '$WIN'로 실행. [access] 집계만 json-log grep 유지.
elif echo "$ARGUMENTS" | grep -qE "^(funnel|cohort)( |$)"; then
  # 활성화·리텐션 분석 — "활성화·리텐션 분석" 섹션의 A~D 쿼리(app_logs)를 따른다.
  # 활성화 윈도우 기본 30d(짧으면 과소집계), 리텐션 D1/D7은 윈도우 무시 전체 기간.
  W=$(echo "$ARGUMENTS" | awk '{print $2}'); W=${W:-30d}
  WIN="${W%d} days"   # "7d" → "7 days"
  # → A) 퍼널, B) 유저별 마일스톤, C) 리텐션, D) 설치일 코호트 실행. 한계 명시해 보고.
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
