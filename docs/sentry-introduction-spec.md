# Sentry 도입 (크래시·에러 리포팅) Spec

> **Status:** Draft
> **Date:** 2026-06-02
> **Author:** (auto-generated)
> **Scope:** `launch-readiness-spec` O7(Sentry/크래시 리포팅, 출시 후 fast-follow)을 구현 가능한 트랙으로 분할한다. 백엔드(FastAPI)·iOS(SwiftUI) 양쪽에 Sentry SDK를 도입해 미처리 예외·크래시를 중앙 수집하고, **분산 트레이스 전파(공유 trace_id)** 로 iOS↔BE 이벤트를 연결하며, **모든 로그(BE 파일 로그·FE 로그)에 trace_id를 포함**시켜 기존 관측 인프라(request_id, GIT_SHA/버전 태깅)와 상관(correlate)되게 한다.
> **상위 문서:** `docs/launch-readiness-implementation-spec.md`(O7은 §1.3 Out of Scope로 분리됨 — 본 스펙이 그 후속).

---

## 1. Background

### 1.1 현재 상태

출시 준비 작업(Track A–H)으로 다음 관측 인프라가 이미 구축됨:

- **백엔드**: 요청 로깅 미들웨어가 request_id를 생성·contextvar로 전파하고 **미처리 예외를 잡아 500 + request_id로 반환**한다(`app/middleware/request_log.py:33-44`). startup 로그에 `APP_VERSION`/`GIT_SHA`/`ENVIRONMENT`를 남긴다(`app/main.py:41-48`, `app/core/config.py:25-27`). 로그는 `RotatingFileHandler`로 파일에 적재(`app/core/logging.py`).
- **iOS**: `LogService`가 FE 로그를 디스크 버퍼링·재시도하며 `POST /api/dev/log/batch`로 백엔드에 전송(`ScatchLM/Services/LogService.swift`). `APIClient`가 응답 `X-Request-Id`를 로그에 동봉(`ScatchLM/Services/APIClient.swift`).

**빠진 것(O7):** 미처리 예외·**iOS 크래시**(앱 강제 종료, ANR, 메모리/시그널)는 어디에도 집계되지 않는다. 백엔드 미처리 예외는 로그 파일에만 남아 알림·추적·그룹화가 없고, iOS 크래시는 LogService가 잡지 못한다(프로세스가 죽으면 flush 전에 종료). Sentry는 이 공백을 메운다.

### 1.2 Out of Scope

| 항목 | 이유 |
|---|---|
| 중앙 로그 수집기(O8 일부) | Sentry는 *에러/크래시* 집계용. 일반 access/info 로그 수집은 별도 인프라 결정 |
| 비즈니스 분석(DAU/MAU) | Sentry 범위 아님. `launch-readiness-spec` §9.1 |
| 성능 APM 전면 도입(분산 트레이싱 100%) | 초기엔 낮은 sample rate로 시작. 본격 트레이싱은 비용·노이즈 보고 단계적 확대 |
| Session Replay(iOS) | PII(손글씨·교재) 노출 위험 큼. 도입 보류 |
| 자체 호스팅 Sentry(self-hosted) | 운영 부담. 초기는 SaaS(sentry.io) free/team tier |
| 알림 라우팅 세부(Slack/PagerDuty 연동) | Sentry 프로젝트 생성 후 대시보드에서 설정 — 코드 무관, §6.x |

### 1.3 기존 코드 정리 대상

- 없음(신규 추가만). 단, **Track A는 `request_log.py`의 미처리 예외 except 블록에 `sentry_sdk.capture_exception()` 호출을 끼워야** 한다(미들웨어가 예외를 swallow하므로 Sentry ASGI 통합이 자동 포착 못 함 — §6-1).

---

## 2. 시스템 도식 (변경 지점)

```
iOS App (SwiftUI)                         Backend (FastAPI)
─────────────────                         ─────────────────
크래시/ANR/시그널 ─┐                       미처리 예외 ─┐
NSError/throw    ─┼─[B]→ Sentry Cocoa     HTTPException(5xx) ─┤
                  │      SDK                                  ├─[A]→ sentry-sdk
LogService(기존)  │      (init in App)     RequestLogMW ──────┘     (init before app)
  → /dev/log/batch│        │                  capture_exception        │
                  └────────┼──────────────────────┬────────────────────┘
                           ▼                       ▼
iOS APIClient ──[sentry-trace / baggage 헤더]──▶ Backend (트레이스 continue)
                    ┌──────────────────────────────────────┐
                    │            sentry.io                  │
                    │  proj: scatchlm-ios | scatchlm-backend│
                    │  ★ 공유 trace_id 로 iOS↔BE 이벤트 연결  │
                    │  공통 태그: environment, release       │
                    └──────────────────────────────────────┘
                           [C] DSN 발급·주입 / dSYM 업로드
```

**핵심:** A·B는 **서로 우리 API를 호출하지 않지만**, iOS SDK가 outgoing HTTP 요청에 **`sentry-trace`/`baggage` 헤더를 주입**하고 백엔드 SDK가 그 트레이스를 **이어받는다(continue)**. 결과적으로 한 사고의 iOS·BE 이벤트가 **동일 `trace_id`**를 갖는다. 이 **전파 헤더 계약**(§3)이 두 트랙을 잇는 진짜 인터페이스다 — request_id tag 매칭(약한 상관)이 아니라 Sentry 네이티브 분산 트레이싱(강한 상관).

---

## 3. 계약: 분산 트레이스 전파 (동결)

Sentry 도입엔 **우리 BE↔FE REST 계약은 없다**(SDK가 sentry.io로 직접 전송). 하지만 iOS·BE 이벤트를 한 사고로 **강하게 상관**시키기 위해, iOS가 백엔드로 보내는 HTTP 요청에 **Sentry 트레이스 전파 헤더를 주입**하고 백엔드가 그 트레이스를 **이어받는다**. 이 전파 헤더가 두 트랙을 잇는 동결 인터페이스다.

### 3.1 트레이스 전파 헤더 (동결)

iOS → Backend 요청에 SDK가 자동 첨부, 백엔드 SDK가 자동 파싱(FastAPI/ASGI 통합). **헤더명·포맷은 Sentry SDK 표준이므로 직접 만들지 않는다 — "이 헤더들이 흐른다"는 사실을 동결**하는 것이 계약이다.

| 헤더 | 방향 | 포맷 | 의미 |
|---|---|---|---|
| `sentry-trace` | iOS→BE (요청) | `{trace_id}-{span_id}-{sampled}` (예: `d4cd…b1-7c2…-1`) | 트레이스/부모 span 식별 + sampling 결정 전파 |
| `baggage` | iOS→BE (요청) | W3C baggage (`sentry-trace_id=…,sentry-environment=…,sentry-release=…,sentry-public_key=…` 등) | 트레이스 메타(환경/릴리스 등) 동적 전파 |

**전파 메커니즘(코드 직접 구현 아님 — SDK 옵션 설정):**
- **iOS(B-2/B-3):** `tracePropagationTargets`에 백엔드 호스트(`scatchlm.duckdns.org`, dev IP)를 등록하면 SDK의 URLSession 계측이 outgoing 요청에 위 두 헤더를 자동 주입. (대상 외 도메인엔 헤더 안 붙음 — Anthropic 등 외부로 누출 방지.)
- **Backend(A-2):** sentry-sdk FastAPI/ASGI 통합이 incoming 요청의 `sentry-trace`/`baggage`를 읽어 **같은 trace_id로 트레이스를 continue**. 별도 코드 불필요(통합 활성화만).
- **결과:** iOS 에러 이벤트와 그 요청이 유발한 BE 에러 이벤트가 **동일 `trace_id`** 를 가져 Sentry "Trace" 뷰에서 한 줄로 연결된다.

> **샘플링 주의(동결):** trace_id 상관은 **performance 샘플링과 무관하게** 동작해야 한다. 최신 Sentry SDK는 `traces_sample_rate=0`이어도 에러 이벤트에 trace_id를 붙이고 전파 헤더를 보낸다("tracing without performance"). 따라서 비용 절감을 위해 `traces_sample_rate`는 낮게(0~0.05) 두되, **전파 자체는 끄지 않는다**(`tracePropagationTargets`는 항상 설정). 단, 이 동작은 SDK 버전 의존 → §6.x-7에서 실측 검증.

### 3.2 공통 스코프 키 (동결, 보조 상관)

trace_id가 1차 상관 키. 아래는 검색·필터·그룹화용 보조 태그다.

| 키 | 의미 | 백엔드 값 출처 | iOS 값 출처 |
|---|---|---|---|
| `environment` | 배포 환경 | `settings.ENVIRONMENT`(`dev`/`prod`) | `#if DEBUG`→`dev`, else `prod` |
| `release` | 빌드 식별 (regression 추적) | `scatchlm-backend@{GIT_SHA}` (`settings.GIT_SHA`) | `com.joho54.scatchlm@{MARKETING_VERSION}+{CURRENT_PROJECT_VERSION}` |
| `request_id` (tag) | **우리 로그**(uvicorn.log/FE 로그)와의 상관 키 | contextvar `get_request_id()` | 응답 `X-Request-Id`(APIClient 추출) |
| `user.id` (선택) | 영향 유저 범위 | `user_id`(JWT sub) | `AuthService.syncUserId` |

- `release` 포맷 **동결**: `<package>@<version>`.
- `request_id`는 trace_id를 **대체하지 않는다** — Sentry↔우리 파일 로그를 잇는 용도(trace_id는 우리 로그엔 없으므로). 둘 다 유지.
- `user.id`만 식별자로 전송, **email·이름 절대 금지**(§7 PII).

### 3.3 PII 스크러빙 정책 (동결 — 양 트랙 공통)

이 앱은 **손글씨 이미지·교재 텍스트·채팅 본문·이메일**을 다룬다. Sentry 이벤트에 이들이 새면 안 된다.

- `send_default_pii = False` (양 SDK 공통).
- **request body / response body를 이벤트에 첨부하지 않는다**(기본값 유지, 명시적으로 attach 금지).
- `before_send` 훅에서 추가 스크럽: `Authorization` 헤더, `image`/`content`/`message`/`email` 키, 폼 필드 `previous_context`/`prompt_context_snippet` 제거.
- iOS: 네트워크 breadcrumb는 URL+status만(본문 미포함, 기본값). Session Replay 미사용(§1.2).

---

## 4. 구현 설계

### 4.1 백엔드 (sentry-sdk)

- 의존성: `requirements.txt`에 `sentry-sdk[fastapi]` 추가(FastAPI/Starlette/asyncio 통합 포함). 핀 버전 명시.
- 초기화 위치: **`app/main.py` 최상단, `app = FastAPI(...)` 생성 전**(`main.py:18` 이전). `sentry_sdk.init(dsn=..., environment=..., release=..., traces_sample_rate=..., send_default_pii=False, before_send=...)`. DSN이 빈 문자열이면 SDK는 **no-op**(dev 안전).
- **트레이스 continue**: FastAPI/ASGI 통합이 incoming `sentry-trace`/`baggage`를 자동 파싱해 iOS가 시작한 트레이스를 이어받음 — **별도 코드 없음**(통합 활성화만, §3.1). CORS `allow_headers`가 두 헤더를 허용해야 함(현재 `["*"]`이라 OK — §6-9). 단 iOS 네이티브는 CORS 무관이라 사실상 항상 흐름.
- 미처리 예외 포착: `app/middleware/request_log.py`의 `except Exception:` 블록(`:33`)에서 `sentry_sdk.capture_exception()` 호출. (미들웨어가 예외를 swallow하므로 자동 통합만으로는 누락 — §6-1.) 이때 잡힌 이벤트도 continue된 trace_id를 가짐.
- request_id 태그: 미들웨어 dispatch 진입부에서 `sentry_sdk.set_tag("request_id", request_id)` + `set_user({"id": ...})`(가능 시). FastAPI 통합이 요청별 스코프를 격리.
- 설정 env: `core/config.py`에 `SENTRY_DSN`, `SENTRY_TRACES_SAMPLE_RATE`(기본 0.0 또는 0.05) 추가. `release`는 `settings.GIT_SHA`, `environment`는 `settings.ENVIRONMENT` 재사용(신규 env 불필요). traces_sample_rate=0이어도 trace 전파/상관은 유지(§3.1 주의).

### 4.2 iOS (sentry-cocoa)

- 의존성: `project.yml` `packages:`에 Sentry(`https://github.com/getsentry/sentry-cocoa`, from `8.0.0`) 추가, `ScatchLM` target `dependencies`에 `product: Sentry` 추가(`project.yml:8-17,40-46`). `xcodegen generate`.
- 초기화 위치: `ScatchLMApp` `init()`(현재 `@main struct ScatchLMApp`, `App/ScatchLMApp.swift:11`) 또는 `AppDelegate`(`:4`). `SentrySDK.start { options in ... }`. DSN 빈 값이면 비활성.
- 옵션: `enableCrashHandler`(기본 on), ANR 추적, `tracesSampleRate`(0.0~0.1), `environment`(DEBUG 분기), `releaseName`/`dist`(`MARKETING_VERSION`+`CURRENT_PROJECT_VERSION`), `beforeSend`로 PII 스크럽.
- **트레이스 전파**: `options.tracePropagationTargets = ["scatchlm.duckdns.org", <dev host>]` 설정 → SDK URLSession 계측이 우리 백엔드 요청에만 `sentry-trace`/`baggage` 주입(§3.1). Anthropic 등 외부엔 미주입.
- **FE 로그에 trace_id 동봉**: `LogService.context()`에 현재 Sentry trace_id(`SentrySDK.span?.traceId.sentryIdString` 또는 활성 propagation context)를 추가 → 모든 FE 로그 라인이 trace_id를 가짐(아래 "모든 로그 trace_id" 요건).
- request_id 상관: `APIClient.validate(...)`가 비-2xx에서 `X-Request-Id`를 이미 추출(`APIClient.swift`). 에러 capture 시 `request_id` tag 동봉(trace_id는 SDK가 자동).
- DSN 설정 위치: `Config.swift`에 `sentryDSN`(빈 문자열 기본, 빌드설정/Info.plist 주입 가능).

### 4.3 모든 로그에 trace_id 포함 (신규 요건)

현재 로그 포맷은 `request_id`만 담는다(BE: `app/core/logging.py`의 `[%(request_id)s]`; FE: devlog가 request_id만). **trace_id가 모든 로그 라인에 들어가야** Sentry 트레이스 ↔ 우리 파일 로그가 trace 단위로 이어진다.

- **trace_id 출처(BE, Sentry 비의존):** 미들웨어가 incoming `sentry-trace` 헤더의 앞부분(`{trace_id}-…`)을 파싱해 그 값을 쓰고, 없으면 `uuid4().hex`(32-hex, Sentry trace_id 포맷)를 **자체 생성**한다. → **Sentry DSN이 비어 있어도(no-op) 로그 trace_id는 항상 존재**. Sentry가 켜져 있으면 동일 trace_id를 Sentry 스코프에도 set해 이벤트와 로그가 일치.
- **전파 contextvar:** `app/core/request_context.py`에 `trace_id` contextvar 추가(`request_id`와 동일 패턴). 미들웨어가 set, `RequestContextFilter`가 레코드에 주입.
- **포맷:** `logging.py` 포맷 문자열을 `… [trace:%(trace_id)s req:%(request_id)s] …`로 확장. 모든 핸들러(stdout/app.log/fe.log)에 동일 필터 적용.
- **FE 로그:** iOS가 context에 trace_id를 실어 보냄(§4.2). `devlog.py`가 이를 읽어 FE 로그 라인 prefix에 `[trace:…]` 추가(현재 request_id만 출력).

### 4.4 데이터 모델 변경

- 없음(DB/마이그레이션 무관, GRDB 무관).

---

## 5. 구현 단계 (Tracks)

### 5.1 의존성 그래프

```
트레이스 전파 계약 동결(§3, 이 문서) ─── 전 트랙 전제. 완료됨.
        │
        ├── Track A (BE: sentry-sdk + 로그 trace_id)  ─ 독립
        ├── Track B (iOS: sentry-cocoa + trace 전파)  ─ 독립
        └── Track C (인프라: Sentry 프로젝트·DSN·dSYM·배포)
              C-1 Sentry.io 프로젝트 2개 생성·DSN 발급
                    └→ A/B의 *런타임 검증*에 DSN 필요(코드 작성은 DSN 없이 가능)
              C-2 .env.prod / Config DSN 주입
              C-3 dSYM 업로드(iOS 심볼리케이션) — B 빌드 산출물 필요
```

### 5.2 트랙 간 의존성

- **A·B는 코드상 완전 독립**(다른 repo·다른 파일, 우리 REST 계약 없음). §3 트레이스 전파 계약(헤더)만 공유 — SDK가 자동 처리하므로 양쪽이 옵션만 맞추면 됨.
- **C-1(DSN 발급)**은 A·B의 *런타임 검증*(실제 이벤트 전송 확인)에 필요. 단, DSN이 빈 값이면 양 SDK가 no-op이라 **코드 구현·컴파일은 DSN 없이 독립 진행** 가능(가짜 병렬 아님).
- **C-3(dSYM 업로드)**은 Track B 빌드 산출물이 있어야 함 → B 이후.
- `main.py`는 A만 손대고(Track A–H에서 hub였지만 여기선 A 단독), `project.yml`은 B만 손댐 → 충돌 없음.

### 5.3 인원별 배분

| 인원 | 추천 배분 |
|---|---|
| 1명 | C-1(DSN 발급) → A → B → C-2/C-3. (DSN 먼저 받아두면 검증까지 한 번에) |
| 2명 | **개발자1(BE):** A + C-2(prod env). **개발자2(iOS):** B + C-3(dSYM). C-1은 둘 중 먼저 하는 사람이. |
| 3명+ | A / B / C 각각. C가 DSN을 먼저 발급해 A·B에 공유. |

---

### Track A — BE: sentry-sdk 통합 + 로그 trace_id
**의존:** 없음(런타임 검증만 C-1 DSN 필요). §3 계약 동결됨.
**내부 순서:** A-1 → A-2 → A-3 (init 먼저, 그 위에 capture/scope). **A-4(로그 trace_id)는 A-2와 병렬 가능** — Sentry init과 독립(trace_id는 자체 생성 fallback 보유, §4.3). 단 같은 `request_log.py`를 만지므로 A-3와는 순차 머지.
**작업량:** 중간. 가장 복잡: A-2의 `before_send` PII 스크럽 + 미들웨어 swallow 보정, A-4의 trace_id 자체 생성/Sentry 정합.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `requirements.txt`, `app/core/config.py` | `sentry-sdk[fastapi]` 핀 추가. `SENTRY_DSN`, `SENTRY_TRACES_SAMPLE_RATE` env 추가(`release`/`environment`는 기존 `GIT_SHA`/`ENVIRONMENT` 재사용) |
| A-2 | `app/main.py` | `app = FastAPI` 생성 **전**에 `sentry_sdk.init(...)`. DSN 빈 값이면 no-op. `before_send`로 PII(헤더/body/image/content/email) 스크럽. `release="scatchlm-backend@{GIT_SHA}"`, `environment=settings.ENVIRONMENT` |
| A-3 | `app/middleware/request_log.py` | dispatch 진입부 `set_tag("request_id", ...)`(+가능 시 `set_user`). `except Exception:` 블록(`:33`)에 `sentry_sdk.capture_exception()` 추가(swallow 보정). 4xx는 캡처 안 함, 5xx/미처리만 |
| A-4 | `app/core/request_context.py`, `app/core/logging.py`, `app/middleware/request_log.py`, `app/routers/devlog.py` | **모든 로그에 trace_id**(§4.3). `trace_id` contextvar 추가 + `RequestContextFilter` 주입. 미들웨어가 incoming `sentry-trace` 파싱(없으면 `uuid4().hex` 생성)해 contextvar·Sentry 스코프에 set. 포맷 `[trace:%(trace_id)s req:%(request_id)s]`. devlog가 FE trace_id를 라인에 출력 |

**검증:** `SENTRY_DSN` 설정 후 의도적 5xx(임시 라우트 `raise`) → Sentry 대시보드에 이벤트 + `request_id` tag + `release`/`environment` 노출. 4xx(404 등)는 이벤트 안 생김. 이벤트 payload에 Authorization/이미지/본문 없음 확인. **DSN 빈 값에서도** `uvicorn.log`의 모든 라인에 `[trace:…]` 존재. iOS가 보낸 요청은 BE 로그 trace_id == iOS Sentry trace_id.

---

### Track B — iOS: sentry-cocoa 통합 + trace 전파
**의존:** 없음(런타임 검증만 C-1 DSN 필요). §3 계약 동결됨.
**내부 순서:** B-1 → B-2 → B-3.
**작업량:** 중간. 가장 복잡: B-2 init 옵션(release/dist/environment/PII beforeSend + `tracePropagationTargets`) + B-3 trace_id/request_id 상관·LogService context 확장.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `project.yml`, `Config.swift` | `packages:`에 sentry-cocoa(from 8.0.0), target `dependencies`에 `product: Sentry`. `Config.sentryDSN`(빈 값 기본). `xcodegen generate` |
| B-2 | `App/ScatchLMApp.swift` | `init()`에서 `SentrySDK.start { ... }`: crash handler·ANR on, `tracesSampleRate` 낮게, `environment`(DEBUG 분기), `releaseName`(`com.joho54.scatchlm@{MARKETING_VERSION}+{CURRENT_PROJECT_VERSION}`), `beforeSend` PII 스크럽, `send_default_pii=false`, **`tracePropagationTargets`에 백엔드 호스트**(§3.1) |
| B-3 | `APIClient.swift`, `AuthService.swift`, `LogService.swift` | API 에러/세션 이벤트에 `request_id` tag·`user.id`(syncUserId) 스코프(*에러*만 Sentry로, LogService 전송과 중복 회피). **`LogService.context()`에 현재 trace_id 추가**(§4.3) → 모든 FE 로그가 trace_id 동봉 |

**검증:** DSN 설정 후 시뮬레이터/실기기에서 의도적 크래시(`fatalError` 임시) → 재실행 시 Sentry에 크래시 이벤트 + `release`/`environment` + dSYM 심볼리케이션. PII(이미지·이메일) 미노출 확인. iOS 에러와 그 요청의 BE 에러가 Sentry Trace 뷰에서 **동일 trace_id로 연결**. FE 로그 라인에 `[trace:…]` 존재. 빌드: 실기기+시뮬레이터(CLAUDE.md 정책).

---

### Track C — 인프라: Sentry 프로젝트·DSN·dSYM·배포
**의존:** C-1은 독립(가장 먼저). C-3은 Track B 빌드 후.
**내부 순서:** C-1 → C-2 → C-3.
**작업량:** 작음~중간. 가장 복잡: C-3 dSYM 자동 업로드(빌드 파이프라인 연동).

| ID | 대상 | 내용 |
|---|---|---|
| C-1 | sentry.io 대시보드 | 조직 + 프로젝트 2개(`scatchlm-backend`: Python, `scatchlm-ios`: Apple/Cocoa) 생성. 각 DSN 발급. (코드 무관 수동) |
| C-2 | `backend/.env.prod`, `.env.prod.example`, iOS DSN 주입 | BE `SENTRY_DSN`/`SENTRY_TRACES_SAMPLE_RATE`를 `.env.prod`에 주입(+example 문서화). iOS DSN을 `Config.sentryDSN` 또는 빌드설정/Info.plist로 주입(커밋 금지 값은 별도 관리) |
| C-3 | iOS 빌드, `sentry-cli`/fastlane | 릴리스 빌드 시 dSYM을 Sentry에 업로드(심볼리케이션). 수동(`sentry-cli upload-dif`) 또는 빌드 phase 스크립트. 백엔드는 소스맵 불필요 |

**검증:** prod `/health` 정상 + Sentry 대시보드에 BE/iOS 프로젝트 이벤트 수신, iOS 크래시가 심볼리케이션되어 함수명·라인 노출.

---

## 6. 확인 완료 사항 (코드 검증)

1. **미들웨어가 미처리 예외를 swallow** — `app/middleware/request_log.py:33-44`의 `except Exception:`이 예외를 잡아 JSONResponse(500)로 반환한다. → Sentry FastAPI/ASGI 통합은 *전파되는* 예외만 자동 포착하므로, 이 블록에서 **명시적 `capture_exception()` 호출 필수**(A-3). 안 하면 미처리 5xx가 Sentry에 안 잡힌다.
2. **release/environment env가 이미 존재** — `app/core/config.py:25-27`에 `APP_VERSION`/`GIT_SHA`/`ENVIRONMENT`. → Sentry `release`/`environment`에 **재사용**(신규 env 불필요). 단 prod에서 `GIT_SHA`가 실제 SHA로 주입돼야 regression 추적 의미 있음(`docs/launch-app-store-connect.md` G-2 체크리스트의 `GIT_SHA` 항목).
3. **request_id contextvar 인프라 존재** — `app/core/request_context.py`의 `get_request_id()` + 미들웨어 전파. → Sentry tag로 그대로 연결(A-3).
4. **iOS가 X-Request-Id 추출 중** — `ScatchLM/Services/APIClient.swift`의 `validate(...)`가 응답 헤더에서 `X-Request-Id`를 읽어 로그에 동봉. → Sentry tag 상관에 재사용(B-3).
5. **iOS SPM 패키지 구조** — `project.yml:8-17`(packages) + `:40-46`(dependencies)에 Supabase/GRDB/MarkdownUI가 SPM으로 연결됨. → sentry-cocoa 동일 패턴 추가(B-1).
6. **iOS 버전 env 존재** — `project.yml`에 `MARKETING_VERSION=1.0.0`/`CURRENT_PROJECT_VERSION=1`(Track D에서 추가됨). → Sentry `releaseName`/`dist`에 사용(B-2).
7. **PII 표면 다수** — 손글씨 이미지(`/feedback` multipart), 채팅 본문(`/feedback/chat`), 이메일(JWT), 교재 텍스트(`prompt_context_snippet`). `app/core/log_sanitize.py`가 로그용 마스킹은 하지만 **Sentry 이벤트는 별도 경로** → §3.3 스크럽 정책 필수.
8. **Sentry 미사용 확인** — `grep -rin sentry app/` 0건, `requirements.txt`에 없음. iOS도 동일. → 순수 신규 도입.
9. **현 로그 포맷에 trace_id 없음** — `app/core/logging.py`의 포맷 문자열은 `… [%(request_id)s] …`로 **request_id만** 담는다(`RequestContextFilter`가 request_id만 주입, `app/core/request_context.py`). FE 로그(`app/routers/devlog.py`)도 request_id만. → A-4가 `trace_id` contextvar·필터·포맷·devlog를 확장해야 "모든 로그 trace_id" 충족(§4.3).
10. **CORS가 trace 헤더 허용** — `app/main.py`의 CORS `allow_headers=["*"]`라 `sentry-trace`/`baggage` 수신 차단 없음. (iOS 네이티브는 어차피 CORS 무관.) → 트레이스 continue에 추가 작업 불필요.
11. **iOS HTTP 클라이언트 구조** — `APIClient`가 `URLSession.shared` + 커스텀 `URLSession(configuration:)`을 쓴다(`ScatchLM/Services/APIClient.swift`). sentry-cocoa는 URLSession을 swizzle로 자동 계측하므로 두 세션 모두 트레이스 헤더 주입 대상. → §6.x-8에서 커스텀 세션 계측 실측 확인.

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | sentry.io tier(free/team) 이벤트 quota가 예상 트래픽에 충분한가 | 베타 사용량 추정 후 대시보드 quota 확인. 초과 시 sample rate 조정 |
| 2 | `sentry-sdk[fastapi]` 정확한 핀 버전(현 FastAPI 0.135 호환) | `pip index versions sentry-sdk` + 통합 테스트 |
| 3 | sentry-cocoa 8.x가 iOS 17 deploymentTarget·Swift 5.9와 호환 | SPM resolve + 시뮬레이터 빌드 |
| 4 | dSYM 업로드 방식(수동 sentry-cli vs Xcode build phase vs CI) | 빌드 파이프라인 현황 확인. 현재 CI 자동화 없으면 수동 |
| 5 | 알림 라우팅(이메일/Slack) | Sentry 프로젝트 Alerts 설정 — 코드 무관, 운영 결정 |
| 6 | `before_send` 스크럽이 ASGI 통합이 자동 첨부하는 필드(쿼리스트링 등)까지 덮는가 | 실제 이벤트 payload 검사로 검증 |
| 7 | `traces_sample_rate=0`에서도 trace_id 전파/상관이 되는가(SDK 버전 의존, §3.1) | sentry-sdk·sentry-cocoa 버전 확정 후 실측: iOS 요청 → BE 로그·이벤트 trace_id 일치 확인. 안 되면 최소 sample rate(예 0.01)로 상향 |
| 8 | iOS 커스텀 `URLSession(configuration:)`도 자동 계측되어 trace 헤더가 주입되는가(§6-11) | 요청 헤더 캡처로 `sentry-trace` 존재 확인. 미주입이면 수동 헤더 주입(`SentrySDK`로 traceparent 생성) |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| PII 유출(손글씨·채팅·이메일이 Sentry 이벤트에 첨부) | 높 | §3.3 동결: `send_default_pii=False` + `before_send` 스크럽 + body 미첨부 + Session Replay 미사용. 출시 전 실제 payload 1건 수동 검사 |
| 미들웨어 swallow로 5xx 누락(자동 통합만 믿음) | 중 | A-3에서 except 블록에 명시적 `capture_exception()`. 검증에 의도적 5xx 포함 |
| 이벤트 quota 초과(비용/누락) | 중 | traces_sample_rate 낮게(0~0.05) 시작, error 이벤트 위주. §6.x-1 |
| iOS 크래시가 심볼리케이션 안 됨(dSYM 누락) | 중 | C-3 dSYM 업로드. 누락 시 함수명 없는 주소만 보여 무용 |
| DSN 커밋(시크릿 유출) | 중 | DSN은 `.env.prod`/빌드설정으로 주입, 커밋 금지. (DSN은 write-only라 치명도는 키보다 낮으나 스팸 위험) |
| 노이즈(취소·오프라인 등 정상 에러까지 캡처) | 낮 | iOS는 *에러*만 캡처(B-3), 취소(`CancellationError`/4.8 사용자취소)·오프라인은 필터. BE는 4xx 제외 |
| prod에서 GIT_SHA 미주입 → release 추적 무의미 | 낮 | G-2 배포 체크리스트의 `GIT_SHA` 주입 항목 재확인(`docs/launch-app-store-connect.md`) |
| 트레이스 헤더가 외부 호스트(Anthropic/Voyage/Supabase)로 누출 | 중 | iOS `tracePropagationTargets`를 **우리 백엔드 호스트로 한정**(§3.1). 와일드카드/기본값(모든 호스트) 사용 금지 |
| `traces_sample_rate=0`에서 trace_id 상관 미동작(SDK 버전 의존) | 중 | §6.x-7 실측 검증. 안 되면 최소 sample rate로 상향(전파만 보장되면 비용 영향 적음) |
| 로그 trace_id가 Sentry trace_id와 불일치(자체 생성 fallback과 SDK 내부값 분기) | 중 | A-4에서 **단일 출처 강제**: 미들웨어가 정한 trace_id를 Sentry 스코프에 set(Sentry가 별도 생성 못 하게). §6.x-7 정합 확인 |

---

## 8. 도입 게이트 체크리스트 (요약)

**최소 동작(에러 가시성):** A-1·A-2·A-3(BE 캡처) · B-1·B-2(iOS 크래시) · C-1(DSN) · C-2(DSN 주입).
**상관(trace_id 공유 — 본 개정 핵심):** A-4(모든 로그 trace_id + Sentry 스코프 정합) · B-2 `tracePropagationTargets` · B-3(LogService trace_id). → iOS↔BE 이벤트·로그가 한 trace_id로 연결.
**품질(심볼리케이션):** C-3(dSYM).
**운영(후속):** §6.x-5 알림 라우팅 · §6.x-7 sample rate/전파 실측 · quota 모니터링.
