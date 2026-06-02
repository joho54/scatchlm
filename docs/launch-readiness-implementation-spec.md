# Launch Readiness — Implementation Spec (Tracks & Contracts)

> **Status:** Draft
> **Date:** 2026-06-02
> **Author:** (auto-generated)
> **Scope:** `docs/launch-readiness-spec.md`(점검 결과)의 잔여 작업(L1–L10, O1–O15)을 **구현 가능한 병렬 트랙**으로 분할하고, 트랙 경계를 넘는 API 계약을 동결한다.
> **상위 문서:** 점검·근거는 `docs/launch-readiness-spec.md`. 이 문서는 *무엇을 어떤 순서로, 누가* 구현하는지를 정의한다.

---

## 1. Background

### 1.1 현재 상태

핵심 기능은 구현 완료(`launch-readiness-spec.md` §2). 출시를 막거나 운영을 위협하는 잔여 작업이 다음 3계층으로 남아 있다:

1. **심사 차단(BLOCKER)** — 인앱 계정 삭제, Sign in with Apple, 개인정보 처리방침/약관 (L1–L3)
2. **운영·비용·보안** — sync 프로덕션 배포, LLM 사용량 한도, CORS 제한, admin 권한 가드, 로그 로테이션 (L4–L6, O1–O4)
3. **데이터 정합성·품질·관측성** — `try?` 저장 실패 처리, API 실패 알림, 빈 상태 UI, LogService 신뢰성 개편, FE/BE 로깅 보강 (L7–L10, O5–O15)

### 1.2 핵심 코드 사실 (이 스펙의 전제 — §6에서 라인 인용)

| 사실 | 영향 |
|---|---|
| 백엔드 DB에 admin/role·tier 컬럼은 없지만 **Supabase JWT의 `app_metadata`가 서명된 토큰에 포함되고 유저가 변경 불가** | O1 admin 가드(`app_metadata.role`)·L5 tier(`app_metadata.tier`) 모두 **DB·env 없이** 클레임으로 판정 (마이그레이션 불필요) |
| 백엔드에 **Supabase service-role 클라이언트 없음** (JWT 검증만, auth API 미호출) | L1 계정 삭제의 *Supabase auth 유저 삭제*는 신규 service-role 의존성 필요 |
| `storage.delete(key)`는 **단건 삭제만**, list/prefix 삭제 없음 | L1의 유저 blob 대량 삭제는 **enumerate 경로 부재** → §6.x 미확인 |
| user_id를 가진 테이블이 **FK cascade가 있는 것(sync 4테이블, textbook_sources)과 없는 것(ai_response, ai_response_rating, llm_usage, document_chunks)으로 혼재** | L1 삭제는 테이블별 명시적 delete 필요(단일 cascade 불가) |
| `get_current_user_id`는 JIT 프로비저닝 — 토큰만 유효하면 유저 자동 생성 | 계정 삭제 후 같은 토큰으로 재호출 시 빈 유저 재생성됨(문서화 필요) |

### 1.3 Out of Scope

| 항목 | 이유 |
|---|---|
| 접근성(VoiceOver/Dynamic Type) 전수 점검 | `launch-readiness-spec` §5.6 ❓, 출시 후 |
| 비즈니스 분석(DAU/MAU, 리텐션 파이프라인) | §9.1 ❌, 별도 phase |
| Sentry/크래시 리포팅(O7) | 외부 SaaS 도입 결정 필요 — 출시 후 fast-follow 권장(§7) |
| **결제(IAP)로 pro 업그레이드 (self-serve 구독)** | StoreKit·영수증 검증·entitlement 동기화·별도 심사 = 대형 독립 트랙. launch엔 tier **메커니즘만**(수동 부여), 결제는 post-launch 별도 spec |
| 커스텀 런치스크린·온보딩 | L10 선택 항목, 출시 차단 아님 |
| 중앙 로그 수집기(O8 일부) | 인프라 결정 필요, 출시 후 |

---

## 2. 시스템 도식 (변경 지점)

```
iOS App                                  Backend (FastAPI)
─────────                                ─────────────────
SettingsSheet ──[D]──> DELETE /api/account ──[A]──> users / sync 4테이블 /
   계정삭제                                          ai_response(+rating) /
   Apple로그인 ─[D]─> Supabase(.apple)               llm_usage / textbook(+cascade)
   약관링크                                          + blobs(sync/PDF) + Supabase auth

NoteView/Chat ─[F]─> POST /api/feedback ──[B]──> LLM quota 체크 → 429
   try? 롤백            (429 처리)                   error 분류·PII 마스킹·audit
   에러 alert/toast
   빈 상태 UI

LogService ───[E]───> POST /api/dev/log/batch
   신뢰성 개편          (인증·user_id·request_id 동봉)

모든 요청 ────────────> [C] request-logging 미들웨어
                          (X-Request-Id 응답 헤더, latency, 전역 예외 핸들러)
                          CORS 제한 / /health readiness / 로그 로테이션
```

---

## 3. Backend API Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| DELETE | `/api/account` | 현재 유저 전 데이터·blob·Supabase auth 삭제 | **신규** | §3.2-a |
| POST | `/api/feedback` | 피드백 — quota 초과 시 429 추가 | **변경** | §3.2-b |
| POST | `/api/feedback/chat` | 채팅 — quota 초과 시 429 추가 | **변경** | §3.2-b |
| GET | `/api/admin/usage` | admin 전용으로 제한(403 추가) | **변경** | §3.2-c |
| GET | `/health` | 의존성 체크 readiness | **변경** | §3.2-d |
| (전체) | `*` | 응답에 `X-Request-Id` 헤더 추가 | **변경** | §3.2-e |
| POST | `/api/dev/log/batch` | 인증·user_id·request_id 수용 | **변경** | §3.2-f |

### 3.2 신규/변경 엔드포인트 계약 (동결)

#### 3.2-a DELETE /api/account  *(L1 — Track A)*
- **Request:** `DELETE /api/account`, header `Authorization: Bearer <jwt>`. body 없음.
- **동작:** 현재 `user_id`에 대해 **단일 DB 트랜잭션**으로 아래 테이블 행 삭제 → 트랜잭션 커밋 후 blob 삭제 → 마지막에 Supabase auth 유저 삭제(service-role). 순서가 중요: DB·blob 먼저, auth 마지막(재시도 가능하게).
  - 테이블: `notes`, `note_pages`, `feedbacks`, `chat_messages`(sync), `ai_response`, `ai_response_rating`, `llm_usage`, `textbook_sources`(→ FK cascade로 `document_chunks`·`chapters`·`page_guides`), 마지막 `users`.
  - blob: `sync/{user_id}/*` (드로잉) + 해당 유저 `textbook_sources.server_path` PDF.
- **Response 200:**
  ```json
  {
    "deleted": true,
    "user_id": "a1b2c3...",
    "counts": {
      "notes": 12, "note_pages": 30, "feedbacks": 45, "chat_messages": 88,
      "textbook_sources": 2, "ai_response": 45, "ai_response_rating": 10,
      "llm_usage": 210, "blobs": 33
    },
    "supabase_auth_deleted": true
  }
  ```
- **Error:**
  - `401` — 토큰 무효/만료 (`get_current_user_id` 표준).
  - `500` — DB 삭제 트랜잭션 실패 → **롤백, 아무것도 삭제 안 됨**. `{"detail":"account deletion failed","stage":"db"}`.
  - `502` — DB·blob는 삭제됐으나 Supabase auth 삭제 실패. `{"detail":"data deleted but auth removal failed","supabase_auth_deleted":false}`. **iOS는 이 경우에도 로컬 purge + 로그아웃 진행**(데이터는 이미 삭제됨).
- **멱등성:** 이미 삭제된 유저(또는 JIT로 막 생성된 빈 유저) 재호출 시 200 + counts 전부 0. (JWT가 유효하면 `get_current_user_id`가 빈 유저를 재생성하므로 `users` count는 1일 수 있음 — 정상.)
- **빈 케이스 응답:** counts 전부 0, `supabase_auth_deleted: true`.
- **MSW/모킹:** iOS 단위 테스트는 200/502 두 케이스 스텁. (RN MSW 아님 — Swift `URLProtocol` 스텁 또는 수동 검증.)

#### 3.2-b POST /api/feedback, /api/feedback/chat — quota 429 (비용 기준·tier별)  *(L5 — Track B)*
- **Request:** 기존과 동일.
- **신규 동작:** 요청 처리 **전** 일일 **비용** 사용량 체크. 초과 시 LLM 호출 없이 429.
- **한도 산정:**
  - 기준: **비용**(요청 수 아님). `SUM(cost_usd) FROM llm_usage WHERE user_id=? AND created_at >= 오늘_자정_KST`.
  - 윈도우: **KST(Asia/Seoul) 달력 일** — 자정에 리셋(롤링 24h 아님). `reset_at` = 다음 KST 자정.
  - tier별 한도: JWT `app_metadata.tier`(`"normal"` 기본 | `"pro"`)에 따라 env 한도 선택.
    - `DAILY_COST_LIMIT_NORMAL_USD` (기본값 §6.x-1)
    - `DAILY_COST_LIMIT_PRO_USD`
    - 0/미설정 → 해당 tier 무제한.
  - tier 결정: §3.2-c와 동일하게 **서명 검증된 payload**의 `app_metadata.tier`. 미설정·미인식 값 → `"normal"`.
- **Response 429:**
  ```json
  { "detail": "Daily usage limit reached", "code": "quota_exceeded",
    "tier": "normal", "limit_usd": 1.00, "used_usd": 1.02,
    "reset_at": "2026-06-03T00:00:00+09:00" }
  ```
  header `Retry-After: <다음 KST 자정까지 초>` 동봉.
- **성공 응답:** 기존 피드백/채팅 스키마 변경 없음.
- **iOS 처리(Track F):** status 429 + `code=="quota_exceeded"` → 친화 alert("오늘 사용량을 모두 사용했어요. 내일 다시 시도해 주세요."). `reset_at`·`tier` 표기 선택.
- **pro 부여:** Supabase 대시보드/Admin API로 해당 유저 `app_metadata.tier="pro"` 수동 설정(베타·지인). **결제(IAP) 기반 self-serve 업그레이드는 Out of Scope(§1.3).**

#### 3.2-c GET /api/admin/usage — admin 가드  *(O1 — Track A)*
- **Request:** 기존과 동일(`days`, optional `user_id`).
- **신규 동작:** JWT의 `app_metadata.role`이 `"admin"`이 아니면 거부.
- **Response 403:** `{"detail":"admin access required"}`.
- **Response 200:** 기존 `UsageDashboard` 스키마 변경 없음.
- **admin 판정:** Supabase JWT의 `app_metadata.role == "admin"`. 운영자 본인 유저에 Supabase 대시보드/Admin API로 `app_metadata.role="admin"`을 **1회 설정**. 신규 의존성 `require_admin`(`core/auth.py`)으로 분리해 재사용.
- **🔴 보안 제약:** role은 **서명 검증된 payload**(`_verify_token`의 `jwt.decode(..., signing_key)` 경로, auth.py:33-38)에서만 읽는다. 현재 email 추출에 쓰는 `jwt.decode(raw_token, options={"verify_signature": False})`(auth.py:78) 경로로 role을 읽으면 **위조 가능** — 절대 금지.
- **DB·env·마이그레이션:** 전부 불필요.

#### 3.2-d GET /health — readiness  *(O4 — Track C)*
- **Response 200:** `{"status":"ok","db":"ok","storage":"ok"}` (DB `SELECT 1` + storage 헬스 통과 시).
- **Response 503:** `{"status":"degraded","db":"error","storage":"ok"}` (의존성 1개라도 실패).
- **주의:** 외부 업타임 모니터가 200/503으로 가용성 판단. liveness가 필요하면 `/health/live`(정적 ok) 분리 — 선택.

#### 3.2-e 전역 X-Request-Id  *(O10 — Track C)*
- **동작:** 모든 응답에 `X-Request-Id: <uuid>` 헤더. 요청에 `X-Request-Id`가 오면 echo, 없으면 서버 생성. 미들웨어가 contextvar로 전파해 로그에 동봉.
- **iOS 계약(Track E):** APIClient가 응답 헤더에서 `X-Request-Id`를 읽어 해당 액션의 FE 로그 `data`에 `request_id`로 첨부. 요청 시 클라가 먼저 생성해 보내도 됨(서버가 echo).

#### 3.2-f POST /api/dev/log/batch — 인증·컨텍스트  *(O6/O9/O14 — Track E + C)*
- **Request body(변경):** `{"logs":[{"tag","message","data","level","ts","request_id?"}], "context":{"user_id","app_version","build","os_version","device_model","locale","session_id"}}`.
- **header:** `Authorization: Bearer <jwt>` 첨부(현재 무인증). 릴리스 빌드에서 무인증 거부 또는 샘플링.
- **Response 200:** `{"received": n}`. 인증 실패 401(릴리스), dev 빌드는 관대.
- **하위호환:** `context` optional, 기존 `{"logs":[...]}`도 수용.

---

## 4. 구현 설계 요약

### 4.1 신규 백엔드 모듈
- `app/routers/account.py` — `DELETE /api/account`. 삭제 로직은 `app/services/account_deletion.py`로 분리(테이블별 delete + blob enumerate + supabase 호출).
- `app/services/supabase_admin.py` — service-role 클라이언트(`SUPABASE_SERVICE_ROLE_KEY`). `delete_auth_user(user_id)`.
- `app/core/quota.py` — `check_daily_quota(user_id, tier, db)` → KST 자정 이후 `SUM(cost_usd)`가 tier별 한도 초과 시 `HTTPException(429,...)`. feedback/chat 엔드포인트 진입부에서 호출. tier는 검증된 JWT `app_metadata.tier`.
- `app/core/auth.py` — `require_admin` 의존성 추가. `_verify_token`이 서명 검증된 full payload를 노출(또는 role 전용 헬퍼)하도록 소폭 수정, `app_metadata.role == "admin"` 체크. **서명 미검증 디코드(line 78) 경로 사용 금지.**
- `app/middleware/request_log.py` — request_id 생성·contextvar 전파·access 로그·latency, 전역 예외 핸들러.
- `app/services/storage.py` — `list_keys(prefix)` + `delete_prefix(prefix)` 추가(L1 blob 삭제용).

### 4.2 iOS 변경
- `SettingsSheet.swift` — "계정 삭제" 섹션(확인 다이얼로그), 개인정보 처리방침·약관 링크 섹션, 앱 버전 표기.
- `AuthService.swift` — `deleteAccount()`(API 호출 + 로컬 purge + signOut), `signInWithApple()`.
- `DatabaseService.swift` — `purgeAllData(userId:)`(로컬 전 테이블 행 삭제) — 계정 삭제용. (sync 소프트삭제와 별개의 하드 purge.)
- `LogService.swift` — 전면 개편(O6): 전송 성공 후 dequeue, 실패 재큐잉+backoff, serial queue 직렬화, sanitize, background/terminate flush, 디스크 버퍼, 릴리스 게이팅 + 인증 헤더 + context.
- `APIClient.swift` — `APIError` 친화 문구·`errorDescription`, 429 디코딩, `X-Request-Id` 추출.
- `project.yml` — `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, Sign in with Apple capability.

### 4.3 상태/데이터 모델 변경
- 백엔드 DB 마이그레이션 **Track A–G는 불필요**(테이블 추가 없음 — 모두 삭제/조회/미들웨어, admin·tier는 JWT 클레임). **단 Track H는 alembic 마이그레이션 필요**(`page_guides`에 `response_language` 컬럼·제약 변경 — §Track H). env 변수만 추가(`SUPABASE_SERVICE_ROLE_KEY`, `DAILY_COST_LIMIT_NORMAL_USD`, `DAILY_COST_LIMIT_PRO_USD`, `ALLOWED_ORIGINS`). admin·tier는 env가 아니라 Supabase `app_metadata.role`/`app_metadata.tier` 1회 설정.
- iOS GRDB 마이그레이션 **불필요**(스키마 변경 없음).

---

## 5. 구현 단계 (Tracks)

### 5.1 의존성 그래프

```
계약 동결(§3, 이 문서) ─── 전 트랙의 전제. 완료됨.
        │
        ├── Track A (BE: 계정삭제 + admin가드)
        │     A-2 supabase_admin ─→ A-1 DELETE /api/account
        │     A-3 admin가드 (병렬)
        │
        ├── Track B (BE: quota + upstream/PII/audit)
        │     B-1 quota+429 ─→(같은 파일) B-2 error분류·PII·audit
        │
        ├── Track C (BE: ops/관측 인프라)
        │     C-1 CORS · C-2 로그로테이션 · C-3 /health · C-4 미들웨어+X-Request-Id+예외핸들러+빌드식별
        │
        ├── Track D (iOS: 계정삭제 UI + Apple + 약관/버전)
        │     D-1 ──(통합테스트만 A-1 필요)──> A-1
        │     D-2 Apple로그인 · D-3 약관링크/버전
        │
        ├── Track E (iOS: LogService 신뢰성 + FE로깅)
        │     E-1 O6개편 ─→ E-2 컨텍스트/인증(O9) ─→ E-3 인증·sync·라이프사이클 로깅(O11/O14/O15)
        │     E-2는 C-4의 X-Request-Id 계약 사용(이미 동결)
        │
        ├── Track F (iOS: 데이터정합성 + UX + 429)
        │     F-1 try?롤백+로깅(L7/O11) · F-2 API alert/toast+APIError문구(L8) ·
        │     F-3 빈상태+PDF로딩(L9) · F-4 429처리(B-1 계약)
        │
        ├── Track G (문서/인프라)
        │     G-1 개인정보처리방침·약관 작성·호스팅 ──> D-3(링크 URL 필요)
        │     G-2 sync 프로덕션 배포(L4) · G-3 App Store Connect 메타·버전
        │
        └── Track H (BE: PDF 가이드 캐시 언어 인식) ─ 독립, launch 차단 아님
              H-1 모델+마이그레이션 ─→ H-2 lookup/insert ─→ H-3 iOS response_language 전달 확인
```

### 5.2 트랙 간 의존성

- **D-1 통합 테스트**는 A-1(`DELETE /api/account`) 구현 완료 필요. 단위 개발은 계약(§3.2-a)으로 독립 진행.
- **F-4(429 처리)**는 B-1 계약(§3.2-b)으로 독립 개발. 통합 검증만 B-1 완료 필요.
- **E-2(request_id 동봉)**는 C-4의 `X-Request-Id` 계약(§3.2-e)으로 독립. 실제 stitching 검증은 C-4 완료 필요.
- **D-3(약관 링크)**는 G-1의 호스팅 URL 확정 필요(`scatchlm.duckdns.org/privacy` 등).
- **G-2(prod 배포)**는 sync 코드(완료) 기반 — A/B/C의 BE 변경을 **함께 배포**하는 게 효율적이므로 BE 트랙 완료 후 1회 배포 권장.
- **파일 충돌 주의:** `app/main.py`는 A-1(라우터 등록)·C-1(CORS)·C-3(/health)·C-4(미들웨어)가 모두 손댄다 → 작은 hub 편집, merge로 처리. `routers/feedback.py`는 B-1·B-2가 손대므로 **같은 트랙(B)으로 순차**.
- **Track H**는 완전 독립(다른 트랙과 파일·계약 비겹침, launch 비차단). 단 **유일하게 alembic 마이그레이션을 동반**하므로 배포 시 G-2에 포함되면 `page_guides` 마이그레이션이 함께 적용됨.

### 5.3 인원별 배분

| 인원 | 추천 배분 |
|---|---|
| 1명 | 심사 차단 우선: G-1 → A → D → C → B → F → E (출시 게이트 L1–L3, 약관 먼저) |
| 2명 | **개발자1(BE):** A → B → C → G-2. **개발자2(iOS):** D → F → E. 문서 G-1/G-3는 1이 짬내서. |
| 3명 | **BE:** A+C. **BE2/풀스택:** B+G(문서·배포). **iOS:** D+F+E. |
| 4명 | **BE1:** A(계정삭제·admin). **BE2:** B+C(quota·관측). **iOS1:** D+F(계정삭제UI·UX·정합성). **iOS2:** E(LogService·로깅) + G-1 문서. |

---

### Track A — BE: 계정 삭제 + admin 가드
**의존:** 없음 (계약 §3.2-a/c 동결됨)
**내부 순서:** A-2 → A-1 (A-1이 A-2 사용). A-3 병렬.
**작업량:** 큼. 가장 복잡: A-1의 다중 테이블/blob enumerate 삭제 + Supabase service-role 연동(신규 의존성) + 부분 실패 처리(502).

| ID | 파일 | 내용 |
|---|---|---|
| A-2 | `app/services/supabase_admin.py`(신규), `core/config.py` | service-role 클라이언트. `SUPABASE_SERVICE_ROLE_KEY` env. `delete_auth_user(user_id)` (Supabase Admin REST `DELETE /auth/v1/admin/users/{id}`) |
| A-1 | `app/routers/account.py`(신규), `app/services/account_deletion.py`(신규), `app/services/storage.py`, `main.py` | `DELETE /api/account`. 트랜잭션 내 8테이블 delete → 커밋 → blob enumerate·삭제 → supabase auth 삭제. counts 반환. 502 부분실패 처리. `storage.list_keys`/`delete_prefix` 추가 |
| A-3 | `app/core/auth.py`, `app/routers/admin.py` | `require_admin` 의존성 — 서명 검증된 JWT `app_metadata.role == "admin"` 체크(서명 미검증 line 78 경로 금지). `admin.py`의 `get_current_user_id`를 `require_admin`으로 교체, 403 반환. 운영자 유저에 Supabase 대시보드에서 `app_metadata.role="admin"` 1회 설정 |

**검증:** 테스트 유저 생성 → 데이터 적재 → DELETE → 모든 테이블 0건·blob 0·Supabase 콘솔에서 유저 소거 확인. admin 아닌 유저로 `/api/admin/usage` 403 확인.

---

### Track B — BE: LLM quota + upstream 에러분류·PII·audit
**의존:** 없음 (계약 §3.2-b 동결됨)
**내부 순서:** B-1 → B-2 (둘 다 `routers/feedback.py`·feedback service 수정 — 순차)
**작업량:** 중간. 가장 복잡: B-1 일일 한도 집계 쿼리 + reset_at 계산.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `app/core/quota.py`(신규), `routers/feedback.py`, `core/auth.py`, `core/config.py` | `check_daily_quota(user_id, tier, db)` — KST 자정 이후 `SUM(cost_usd)` ≥ tier별 한도(`DAILY_COST_LIMIT_{NORMAL,PRO}_USD`) 시 429(`§3.2-b`). tier는 검증된 JWT `app_metadata.tier`(`require_admin`과 같은 payload 노출 활용). feedback·chat 진입부 호출. O3: 일일 비용 임계 초과 시 `log.warning` 알림 훅 |
| B-2 | `app/services/feedback_service.py`, retrieval/chat 로그 지점 | O12/C6: Anthropic 429/529/timeout을 except 분기로 분류 로깅. C8: `text[:100]`·`content=%s`·query rewrite 등 사용자 콘텐츠 로그 마스킹/길이제한. C7: admin 접근·인증 이벤트 audit 로그 |

**검증:** 한도 1로 설정 → 2회 요청 시 두 번째 429 + Retry-After. 로그에서 PII 마스킹·429/529 분류 확인.

---

### Track C — BE: 관측·운영 인프라
**의존:** 없음
**내부 순서:** C-1~C-4 병렬(다른 관심사). C-4만 `main.py` 미들웨어 등록.
**작업량:** 중간. 가장 복잡: C-4 미들웨어(request_id contextvar 전파 + 전역 예외 핸들러).

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `app/main.py`, `core/config.py` | CORS `allow_origins`를 `ALLOWED_ORIGINS` env로(L6). iOS 전용이라 빈 화이트리스트도 가능 — 단 dev 편의 위해 env로 |
| C-2 | `app/core/logging.py` | `FileHandler`→`RotatingFileHandler`(maxBytes/backupCount) 또는 logrotate 설정. 디스크 풀 방지(O2) |
| C-3 | `app/main.py` | `/health`에 DB `SELECT 1` + storage 헬스 체크(§3.2-d). 503 분기 |
| C-4 | `app/middleware/request_log.py`(신규), `main.py`, `core/logging.py` | 요청 로깅 미들웨어: 서버 생성 request_id, method/path/status/latency/user_id, `X-Request-Id` 응답 헤더(§3.2-e), 전역 예외 핸들러(O5). startup 로그에 앱 버전·git SHA·env(O13/C5) |

**검증:** 응답 헤더 `X-Request-Id` 존재, 로그에 access 라인·request_id, 의도적 5xx가 예외 핸들러에 잡힘, `/health`가 DB 다운 시 503.

---

### Track D — iOS: 계정 삭제 UI + Sign in with Apple + 약관/버전
**의존:** D-1 통합테스트는 Track A(A-1). D-3 링크는 G-1 URL.
**내부 순서:** D-1·D-2·D-3 병렬(같은 `SettingsSheet.swift` 편집 — 작은 충돌, 한 명이 맡거나 순차 머지).
**작업량:** 큼. 가장 복잡: D-2 Sign in with Apple(Apple Developer 키 + Supabase Apple provider 설정).

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `SettingsSheet.swift`, `AuthService.swift`, `DatabaseService.swift` | "계정 삭제" 섹션(파괴적, 확인 다이얼로그) → `AuthService.deleteAccount()`: `DELETE /api/account` 호출 → 200/502면 `DatabaseService.purgeAllData(userId:)` + `signOut()`. 401·기타 실패는 alert |
| D-2 | `AuthService.swift`, `LoginView.swift`, `project.yml` | `ASAuthorizationAppleIDButton` + `client.auth.signInWithIdToken(provider:.apple)` 또는 OAuth. project.yml에 Sign in with Apple capability. Supabase Apple provider·Apple Developer 키 설정(인프라) |
| D-3 | `SettingsSheet.swift`, `project.yml` | 개인정보 처리방침·이용약관 링크 섹션(G-1 URL). `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 설정. 앱 버전 표기 행 |

**검증:** 계정 삭제 후 재로그인 시 빈 상태, Supabase에 유저 없음. Apple 로그인 실기기 1회 콜백 확인. 설정에서 약관 링크 열림.

---

### Track E — iOS: LogService 신뢰성 + FE 로깅 보강
**의존:** E-2는 C-4 `X-Request-Id` 계약(동결). 그 외 없음.
**내부 순서:** E-1 → E-2 → E-3 (E-1이 큐 구조 재작성하므로 후속이 그 위에 얹힘)
**작업량:** 큼. 가장 복잡: E-1 동시성·재시도·디스크 버퍼 재설계(🔴 신뢰성).

| ID | 파일 | 내용 |
|---|---|---|
| E-1 | `LogService.swift` | O6: ① 전송 **성공 후** dequeue + 실패 재큐잉/지수 backoff ② serial queue/actor로 enqueue·flush 직렬화 ③ 직렬화 불가 값 sanitize ④ background/terminate flush 훅 + 디스크 버퍼 ⑤ 릴리스 게이팅/샘플링 + `Authorization`·user_id 첨부 + release `print` 제거 |
| E-2 | `LogService.swift`, `APIClient.swift`, `Config.swift` | O9/C1: context(OS·앱버전·빌드·디바이스·로케일·session_id) 첨부. C2/O10: APIClient가 응답 `X-Request-Id` 추출해 로그에 동봉. warn 레벨·라운드트립 latency |
| E-3 | `AuthService.swift`, `SyncService.swift`, `ScatchLMApp.swift`, `NoteView.swift` | O14: 로그인·회원가입·OAuth(start/콜백/성공/실패)·로그아웃·세션복원·만료 로깅(PII 제외). O15: sync 성공/볼륨·트리거·onLogin/onLogout·background flush, scenePhase 전환, 카드 삭제(`NoteView:642`) 등 파괴적 액션. O11/C3: `try?` 저장 실패 지점 `appLogError` |

**검증:** 네트워크 끊고 로그 발생 → 복구 후 재전송(유실 0). 백그라운드 전환 시 flush. BE 로그에서 OAuth·sync 볼륨·request_id stitching 확인.

---

### Track F — iOS: 데이터 정합성 + UX + 429
**의존:** F-4는 B-1 계약(동결). 그 외 없음. (E-3과 `NoteView.swift`·`FeedbackChatSheet.swift` 일부 겹침 — `try?` 지점은 F-1이 롤백, E-3이 로깅 → **F-1에서 롤백+로깅 동시 처리하고 E-3은 인증/sync에 집중**하도록 분담 권장)
**내부 순서:** F-1~F-4 병렬(주로 다른 화면)
**작업량:** 중간. 가장 복잡: F-1 저장 실패 시 UI 메모리 배열 롤백 로직.

| ID | 파일 | 내용 |
|---|---|---|
| F-1 | `NoteView.swift`(488,507,551,642), `FeedbackChatSheet.swift`(231,296) | L7/O11: `try?`→ `do/catch`. 저장 실패 시 메모리 배열 롤백 + `appLogError` + 사용자 알림(§5.2) |
| F-2 | `APIClient.swift`, `NoteView.swift`(806), `FeedbackChatSheet.swift`(303), `HomeView.swift`(91,108,123,132) | L8: 무음 실패 → alert/toast. `APIError`에 `errorDescription` 친화 문구·로컬라이즈 |
| F-3 | `HomeView.swift`, `NoteView.swift`(820-844), `FeedbackChatSheet.swift` | L9: 빈 상태 UI(노트/피드백/채팅 0개). PDF 다운로드 진행 표시·타임아웃 안내(§5.3-5.4) |
| F-4 | `APIClient.swift`, `NoteView.swift`, `FeedbackChatSheet.swift` | B-1 429 디코딩(`code=="quota_exceeded"`) → 친화 alert(§3.2-b). `FeedbackChatSheet:282`의 별도 URLSession을 APIClient로 통일(오프라인 일관성, §5.5) |

**검증:** DB 쓰기 강제 실패 시 UI 롤백·알림. 피드백 요청 실패 시 alert. 빈 노트 목록 안내. 한도 초과 시 친화 메시지.

---

### Track G — 문서 / 인프라
**의존:** G-1 → D-3(URL). G-2는 BE 트랙(A/B/C) 완료 후 1회 배포 권장.
**내부 순서:** G-1·G-3 병렬, G-2 마지막.
**작업량:** 중간. 가장 복잡: G-2 prod 배포 + DB 마이그레이션 검증.

| ID | 파일/대상 | 내용 |
|---|---|---|
| G-1 | 정책/약관 문서 + 호스팅 | 개인정보 처리방침·이용약관 작성, `scatchlm.duckdns.org/privacy`·`/terms` 호스팅(Caddy 정적). App Store Connect 개인정보 URL 등록(L2) |
| G-2 | `docker-compose.prod.yml`, prod DB | sync + BE 변경 이미지 빌드/푸시 → prod `pull && up -d` → `alembic upgrade head`(Track A–G는 마이그레이션 없음 → 무영향. **Track H 포함 배포 시 `page_guides` 마이그레이션 적용**) + 신규 env(`SUPABASE_SERVICE_ROLE_KEY`, `DAILY_COST_LIMIT_*`, `ALLOWED_ORIGINS`) 주입(L4) |
| G-3 | App Store Connect | 앱 메타데이터, 스크린샷, 버전/빌드, 심사 노트(계정삭제 위치 안내) |

**검증:** prod에서 sync 동작, `/health` 의존성 ok, 약관 URL 200, 계정 삭제 e2e.

---

### Track H — BE: PDF 가이드 캐시 언어 인식 (per-language)
**의존:** 없음. **launch 차단 아님 — 독립 트랙**(품질/정합성). 다른 트랙과 파일 비겹침(`models/guide.py`·`routers/pdf.py` 가이드 부분).
**내부 순서:** H-1 → H-2 → H-3 (모델·마이그레이션이 lookup 수정의 전제)
**작업량:** 작음. 기존 데이터는 폐기 가능(출시 전 — §6.x-8 해소)이라 백필 없음. 유의점: 챕터 가이드(음수 page 캐시)도 빠짐없이 언어 인식 적용.

**배경(정정된 현황):** 가이드 캐시는 **이미 유저별**이다 — 업로드 dedup이 `(user_id, content_hash)` 스코프(`pdf.py:87-92`)라 같은 PDF도 유저마다 별도 `textbook_id`를 받고, 캐시 키 `(textbook_id, page)`(`uq_page_guide`)가 textbook_id를 통해 유저별로 갈린다. **유저 간 hash 공유 아님.** 진짜 결함은 **캐시 키에 `response_language`가 빠진 것** — `response_language`가 생성엔 흘러가나(`pdf.py:364,475`) lookup/제약엔 없어(`pdf.py:344-350,446-452`), 유저가 피드백 언어를 바꾸면 **이전 언어의 stale 가이드**가 반환된다.

> **⚠️ 마이그레이션 예외:** 이 트랙은 다른 트랙과 달리 **백엔드 alembic 마이그레이션이 필요**하다(컬럼·제약 변경). iOS GRDB는 무관.

| ID | 파일 | 내용 |
|---|---|---|
| H-1 | `app/models/guide.py`, `alembic` 마이그레이션 | `page_guides`에 `response_language` 컬럼(NOT NULL) 추가. `uq_page_guide`를 `(textbook_id, page)` → `(textbook_id, page, response_language)`로 변경. **기존 행은 출시 전이라 폐기 가능 → 마이그레이션에서 `page_guides` 비우고**(또는 drop+recreate) 백필 불필요. (선택) 향후 교재 라이브러리 공유 대비 `user_id` 컬럼도 추가 — 현재는 textbook_id가 유저별이라 **불필요(권장 보류)** |
| H-2 | `app/routers/pdf.py:344-350,385-393,446-452` | 페이지·챕터 가이드 lookup·insert에 `PageGuide.response_language == response_language` 포함. 챕터 가이드(음수 page 캐시)도 동일 적용 |
| H-3 | iOS `PdfViewerView.swift` | `/guide`·`/chapter-guide` 호출에 유저의 feedback language를 `response_language`로 전달하는지 **확인·필요 시 추가**(§6.x). 미전달이면 항상 기본값 `"Korean"`이라 언어 차원이 작동 안 함 |

**검증:** 같은 유저가 페이지 가이드를 Korean으로 1회 생성 → 설정에서 English로 변경 → 같은 페이지 재요청 시 **English 가이드 신규 생성**(stale Korean 아님). 같은 언어 재요청은 캐시 히트(LLM 0).

---

## 6. 확인 완료 사항 (코드 검증)

1. **admin은 JWT 클레임으로 처리** — `app/models/user.py:11-18`에 role 컬럼은 없으나 Supabase JWT의 `app_metadata`가 서명된 토큰에 포함(유저 변경 불가). → O1은 DB·env 없이 `app_metadata.role` 판정. `_verify_token`(auth.py:29-49)이 현재 `sub`만 반환하므로 검증된 payload 노출 소폭 수정 필요. **email 추출용 line 78의 `verify_signature:False` 경로로 role을 읽지 말 것(위조 가능).**
2. **`/api/admin/usage` 무가드** — `app/routers/admin.py:60` `_current_user: str = Depends(get_current_user_id)` 만, admin 체크 없음. `user_id` 쿼리로 타 유저 조회 가능.
3. **Supabase service-role 미사용** — backend `/app`에서 service_role/admin 클라이언트 grep 0건. JWT 검증(`core/auth.py:29-49` JWKS·ES256)만. → L1 auth 삭제는 신규 의존성.
4. **삭제 대상 테이블·FK 혼재** — FK cascade 있음: `textbook_sources`(`models/textbook.py:14`), sync 4테이블(`models/sync.py:35,56,75,101`). FK 없음(수동 delete): `ai_response`/`ai_response_rating`(`models/feedback.py:20,43`), `llm_usage`(`models/usage.py:14`), `document_chunks`(`models/document.py:18`).
5. **`storage.delete`는 단건** — `app/services/storage.py:21-30`. Local `os.remove`, S3 `delete_object`. list/prefix 없음. → L1 blob 대량 삭제 위해 `list_keys` 추가 필요.
6. **CORS 와일드카드** — `app/main.py:12-18` `allow_origins=["*"]` TODO.
7. **/health 정적** — `app/main.py:27-29` `{"status":"ok"}`, 의존성 미검사.
8. **LLM 사용량 기록 전용** — `routers/feedback.py:137-165` LLMUsage 적재만, 한도 체크 없음. `models/usage.py:10-27` 필드 확인.
9. **LogService 결함** — `LogService.swift:6-7,53-70` 큐 인메모리·flush 전 비움·실패 무시·lock 없음. timer 2초.
10. **iOS 설정/인증 현황** — `SettingsSheet.swift:11-54`(언어/렌더/SignOut/Done만), `AuthService.swift:64-84`(email/Google/signOut, Apple 없음). `project.yml`에 MARKETING_VERSION/Sign in with Apple 없음.
11. **`try?` 저장 지점** — `NoteView.swift:488,507,551,642`, `FeedbackChatSheet.swift:231,296` 확인.
12. **DB 마이그레이션 불필요 (Track A–G)** — 신규 테이블/컬럼 없음(삭제·조회·미들웨어·env·JWT 클레임만). admin role은 `users.role` 컬럼이 아니라 Supabase `app_metadata.role`. **단 Track H는 예외** — `page_guides`에 `response_language` 컬럼·제약 변경으로 alembic 마이그레이션 필요.
13. **PDF 가이드 캐시는 유저별이나 언어 비인식** — dedup이 `(user_id, content_hash)` 스코프(`pdf.py:87-92`)라 textbook_id가 유저별 → 가이드(`uq_page_guide (textbook_id, page)`, `guide.py`)도 유저별. 그러나 `response_language`가 lookup·제약에 빠져(`pdf.py:344-350,446-452`) 언어 전환 시 stale. (연구 중 "유저 간 공유" 주장은 오류로 확인.)

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | `DAILY_COST_LIMIT_NORMAL_USD` / `_PRO_USD` 기본값(USD) | **결정됨: 비용 기준·KST 달력 일·tier별(normal/pro).** 구체 금액만 모델 단가·예상 사용량으로 보정 |
| 2 | S3(`STORAGE_BACKEND=s3`)에서 `sync/{user_id}/` prefix list 비용·페이징 | boto3 `list_objects_v2` paginator 구현 + prod 테스트 |
| 3 | Supabase Admin REST 엔드포인트·service-role 권한 정확한 경로 | Supabase 프로젝트 설정 + `DELETE /auth/v1/admin/users/{id}` 실호출 검증 |
| 4 | ~~이메일/비번이 Guideline 4.8 대안으로 인정되는지~~ → **결정됨: Google OAuth 유지가 확정이므로 4.8 적용, Sign in with Apple(D-2)을 출시 차단 필수로 확정.** 이메일/비번 베팅 안 함 | — (해소) |
| 5 | 약관/정책 호스팅 방식(Caddy 정적 vs 별도) | `Caddyfile`에 정적 경로 추가 가능 여부 확인 |
| 6 | 릴리스 빌드 `/api/dev/log/batch` 정책(인증 강제 vs 별도 prod 로그 엔드포인트) | dev 전용 경로 유지 + 릴리스 게이팅 결정 |
| 7 | iOS `PdfViewerView`가 `/guide`·`/chapter-guide`에 `response_language`를 전달하는지 (Track H-3) | `PdfViewerView.swift`에서 호출 쿼리 확인 — 미전달이면 H-3에 추가 |
| 8 | ~~Track H 기존 `page_guides` 처리~~ → **결정됨: 출시 전이라 기존 데이터 폐기 가능. 마이그레이션에서 `page_guides` 비움, 백필 없음.** | — (해소) |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 계정 삭제 부분 실패(DB 삭제 후 Supabase auth 잔존) | 중 | 502 + iOS 로컬 purge 진행. auth 잔존 유저는 빈 상태로 재로그인 가능(데이터 없음). 재시도 가능한 순서 설계(§3.2-a) |
| S3 prefix list/삭제 누락으로 blob 고아 | 중 | §6.x-2 paginator 구현 + counts 검증. 고아 blob은 비용만 — 정합성 깨지지 않음 |
| service-role 키 유출 | 높 | `.env.prod`만, 커밋 금지. backend 컨테이너 내부에서만 사용, 응답에 노출 금지 |
| Sign in with Apple 부재로 4.8 리젝 | 높 | Google OAuth 유지 확정 → D-2 **출시 차단 필수**. Apple Developer 키·Supabase Apple provider 설정 리드타임 선확보 |
| LLM 비용 폭주 | 중 | B-1 일일 한도 + O3 알림. 기본값 보수적으로(§6.x-1) |
| LogService 개편 회귀(로그 자체 유실) | 중 | E-1을 독립 트랙으로, 네트워크 단절 시나리오 수동 검증 |
| BE 변경 다중 트랙의 `main.py` 충돌 | 낮 | hub 파일 작은 편집, merge. C-4(미들웨어)·C-1(CORS)·A-1(라우터)·C-3(/health) 등록 위치 사전 합의 |
| prod 배포 시 env 누락(service-role/limit/origins) | 중 | G-2 체크리스트에 신규 env 3종 명시 |
| admin role을 서명 미검증 경로로 읽어 위조 | 높 | A-3: 반드시 `_verify_token`의 검증된 payload에서만 `app_metadata.role` 읽기 (auth.py:78 경로 금지) |
| 운영자 토큰에 `app_metadata.role` 미반영(설정 전 발급분) | 낮 | role 설정 후 재로그인(토큰 refresh) 1회 필요 — 문서화 |

---

## 8. 출시 게이트 체크리스트 (요약)

**제출 차단(반드시):** A-1(계정삭제 BE) · D-1(계정삭제 UI) · D-2(Apple) · G-1(약관·정책) · D-3(링크) · G-3(ASC 메타).
**강력 권장(운영):** A-3(admin 가드 🔴) · B-1(quota) · C-1(CORS) · C-2(로그로테이션) · E-1(LogService 🔴) · G-2(prod 배포).
**품질(출시 직후 가능):** F-1~F-4 · C-3/C-4 · E-2/E-3 · B-2 · **H(가이드 캐시 언어 인식 — 독립, BE 마이그레이션 1건)**.
