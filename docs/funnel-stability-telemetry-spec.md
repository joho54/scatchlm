# 코어 루프 퍼널·안정성 계측 Spec

> **Status:** Draft
> **Date:** 2026-06-09
> **Author:** joho54 + Claude
> **선행 스펙:** [`ux-log-telemetry-spec.md`](./ux-log-telemetry-spec.md) (2026-06-04), [`data-durability-spec.md`](./data-durability-spec.md) (app_logs 적재), `/check-prod-logs` 스킬 funnel 섹션

---

## 0. 목적과 선행 스펙과의 관계 (먼저 화해)

`ux-log-telemetry-spec.md` §1.2/§1.3은 **"흐름마다 호출부를 손으로 래핑하는 산발적 수정은 인프라가 아니므로 폐지"**라고 결정했다. 본 스펙은 그 결정을 **뒤집지 않는다.** 목표가 다르다:

| | 선행 스펙 (06-04) | 본 스펙 (06-09) |
|---|---|---|
| 목표 | **디버깅 인터셉터 인프라** — 인증 실패 사각지대 등 | **제품 지표** — 활성화 퍼널 + step별 실패율로 *방향 1(안정화) 우선순위*를 데이터로 정렬 |
| ROI 근거 | HTTP는 APIClient가 전수 관측 → 호출부 래핑은 중복 | HTTP 인터셉터는 **퍼널 의미론을 못 본다**: 온보딩 단계 전환(비-HTTP), 트리거 여부(no-new-strokes), step 귀속, 캡처 포함 latency. 이게 이탈·안정성 신호의 유일 소스 |
| 범위 | 인터셉터 2곳(B·D)만 | **고정·유한한 퍼널 어휘** 6 step. 개방형 sweep 아님 |

**결정적 사실:** 06-04 이후 `/check-prod-logs`의 funnel SQL이 이미 호출부 메시지(`createNote OK`, `upload OK`, `feedback received`)에 **의존**한다. 즉 프로젝트는 "소수의 잘 고른 호출부 이벤트"를 *사실상 이미 채택*했다. 본 스펙은 그 암묵적 의존을 **명시적·표준 스키마로 동결**하고, 안정성(실패율·지연) 관측에 빠진 최소 이벤트만 보강한다. 이는 "캠페인 sweep"이 아니라 **퍼널의 정의**다.

> 선행 스펙이 out-of-scope로 둔 "대시보드 UI"도 본 스펙은 만들지 않는다 — SQL은 기존 `/check-prod-logs`(grep+psql) 운영 방식 그대로.

---

## 1. Background — 현황 (재사용, 변경 없음)

- **인프라**: `LogService`(`appLog/Warn/Error`, `uxTrack`, 디스크 버퍼+지수 backoff 재시도), `POST /api/dev/log/batch` → `devlog.py._emit` → **`app_logs` 테이블 영속 적재**(2026-06-04~, 배포에도 생존). context: `user_id`(전체 UUID)/`session_id`/`app_version`/`build`/`device_model`/`locale`/`provider`.
- **이미 실재하는 마일스톤 로그** (코드 확인):
  | 메시지 | 위치 |
  |---|---|
  | `createNote OK` | `HomeView.swift:372`, `PhoneHomeView.swift:122` |
  | `upload OK` / `upload failed` | `CreateNoteSheet.swift:200/217`, `NoteMetaSheet.swift:248` |
  | `feedback: start` / `feedback received` / `feedback failed` / `feedback: no new strokes` | `NoteView.swift:1091/1173/1175/1101` |
  | `sync performSync failed` | `SyncService.swift:174` |
- **funnel SQL**: signed in → created note → uploaded textbook → activated(`feedback received`) + 리텐션 D1/D7 (`check-prod-logs.md` §funnel).

---

## 2. 갭 (코드로 확인한 것)

| # | 갭 | 근거 | 영향 |
|---|---|---|---|
| G1 | **온보딩 단계 전환 이벤트 없음** — welcome 노출/`시작`/건너뛰기/마치기 | `OnboardingView`엔 `demo note created`만, welcome/skip/finish 무로그 | 온보딩 이탈·welcome→시작 전환율 측정 불가 |
| G2 | **실패가 "비율"로 안 보임** — step별 attempt/ok/fail를 한 뷰로 못 봄 | funnel SQL은 성공 도달만 셈, 분모 없음 | "어느 step이 얼마나 깨지나" 불가 |
| G3 | **에러 reason 미분류** — raw `\(error)` 문자열 | `NoteView:1175`, `CreateNoteSheet:217` | `GROUP BY reason` 불가 → 원인 트리아지 불가 |
| G4 | **sync 성공 카운터·reason 없음** — 실패만 찍힘 | `SyncService:174`만 | sync 실패율 계산 불가 |
| G5 | **latency 미기록** — feedback/upload에 `ms` 없음 | `requestFeedback`에 start만 | p95 지연(체감 안정성) 못 봄 |
| G6 | **uxTrack 결과 SQL 깨짐** — 쿼리가 `data->>'result'`를 보는데 uxTrack은 result를 *message 접미사*로 남김 | `check-prod-logs.md:110` vs `LogService.swift:305` | ux/uxError 결과 분포가 빈 결과 |

> **크래시/프리즈는 본 스펙 밖** — Sentry 담당(메모리 `project_sentry_spm_deadlock`). app_logs는 "앱 진입 이후 로직 실패"만.

---

## 3. 설계 — 표준 "코어 이벤트" 한 겹

흩어진 메시지 문자열 대신 **단일 헬퍼 + 구조화 필드**(`step`/`result`/`reason`/`ms`)로 통일한다. 기존 message는 하위호환 위해 유지하되, 집계는 `data` 필드로 → 메시지 문구가 바뀌어도 SQL이 안 깨진다(선행 funnel SQL의 "message 문자열 의존" 취약점 G 해소).

### 3.1 이벤트 어휘 (고정·유한)

```
enum FunnelStep:  appOpen | onboardingShown | onboardingStart | onboardingSkip
                | onboardingFinish | noteCreate | textbookUpload | feedback | sync
enum StepResult:  start | ok | fail | empty | cancel
```

`empty` = 사용자가 트리거했으나 입력 없음(`feedback: no new strokes`). `cancel` = 사용자 의도 취소(실패 집계 제외).

### 3.2 헬퍼 (LogService.swift)

```swift
enum FunnelStep: String { case appOpen, onboardingShown, onboardingStart, onboardingSkip,
    onboardingFinish, noteCreate, textbookUpload, feedback, sync }
enum StepResult: String { case start, ok, fail, empty, cancel }

func track(_ step: FunnelStep, _ result: StepResult,
           reason: String? = nil, ms: Int? = nil, _ extra: [String: Any] = [:]) {
    var d: [String: Any] = ["step": step.rawValue, "result": result.rawValue]
    if let reason { d["reason"] = reason }
    if let ms { d["ms"] = ms }
    d.merge(extra) { _, new in new }
    if result == .fail { LogService.shared.error("funnel", step.rawValue, d) }
    else { LogService.shared.info("funnel", step.rawValue, d) }
}
```
- 태그는 단일 `funnel`. `.fail`만 error 레벨(Release 전송 보장 + 에러 SQL에 포함), 나머지 info.
- **기존 마일스톤 로그는 삭제하지 않는다** — `track()`을 *옆에 추가*. 선행 funnel SQL이 당분간 계속 동작.

### 3.3 에러 reason 분류기 (feedback/upload/sync 공용)

```swift
func reasonClass(_ error: Error) -> String {
    if case APIError.quotaExceeded = error { return "quota" }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "offline"
        case NSURLErrorTimedOut: return "timeout"
        default: return "network"
        }
    }
    if let api = error as? APIError { return api.reasonTag }   // http_4xx/http_5xx/http_422/decode
    return "unknown"
}
```
> `APIError.reasonTag`는 `APIClient.swift`의 APIError에 case→문자열 매핑을 추가(§6 확인 필요). 미정의 case는 `unknown`.

---

## 4. 삽입 지점 (최소·정확)

| step | 위치 | 추가 |
|---|---|---|
| `onboardingShown` | `OnboardingView` welcomeStep `.onAppear` | `track(.onboardingShown, .ok)` |
| `onboardingStart` | `startEditor()` (`OnboardingView.swift:~176`) | `track(.onboardingStart, .ok)` |
| `onboardingSkip` | `skip()` (`:~198`) | `track(.onboardingSkip, .ok)` |
| `onboardingFinish` | `finish()` (`:~202`) | `track(.onboardingFinish, .ok, ["gotFeedback": gotFeedback])` |
| `feedback` start | `NoteView.swift:1091` | `track(.feedback, .start)` + start 시각 보관 |
| `feedback` empty | `:1101` | `track(.feedback, .empty)` |
| `feedback` ok | `:1173` | `track(.feedback, .ok, ms: <경과>)` |
| `feedback` fail | `:1175` | `track(.feedback, .fail, reason: reasonClass(error), ms: <경과>)` |
| `textbookUpload` start/ok/fail | `CreateNoteSheet.swift:200/217` (+`NoteMetaSheet:248`) | start 추가 + `ok(ms:)` / `fail(reason:, ms:)` |
| `sync` ok | `performSync` 성공 종료부 | `track(.sync, .ok)` |
| `sync` fail | `SyncService.swift:174` | `track(.sync, .fail, reason: reasonClass(error))` |
| `noteCreate` | `HomeView.swift:372` / `PhoneHomeView.swift:122` | `track(.noteCreate, .ok)` |
| `appOpen` | 앱 launch(`ScatchLMApp`) | `track(.appOpen, .ok)` (세션 시작 분모) |

> feedback start 시각만 잡으면 ok·fail·empty 모든 종료에서 `ms` 산출(캡처+LLM 포함 체감 latency = G5).

---

## 5. SQL 대시보드 (`/check-prod-logs` funnel 보강)

`PSQL`/`WIN`은 스킬 기존 정의 재사용. 내부 계정 제외는 기존 관행(`u.email NOT IN (...)`).

```sql
-- D1) 코어 루프 step별 시도/성공/실패율 + 지연 (안정성 단일 뷰) ★핵심
SELECT data->>'step' AS step,
  count(*) FILTER (WHERE data->>'result'='start') AS attempts,
  count(*) FILTER (WHERE data->>'result'='ok')    AS ok,
  count(*) FILTER (WHERE data->>'result'='fail')  AS fail,
  round(100.0*count(*) FILTER (WHERE data->>'result'='fail')
        / NULLIF(count(*) FILTER (WHERE data->>'result' IN ('ok','fail')),0),1) AS fail_pct,
  percentile_disc(0.5)  WITHIN GROUP (ORDER BY (data->>'ms')::int) AS p50_ms,
  percentile_disc(0.95) WITHIN GROUP (ORDER BY (data->>'ms')::int) AS p95_ms
FROM app_logs WHERE tag='funnel' AND ts > now() - interval '$WIN'
GROUP BY 1 ORDER BY fail DESC;

-- D2) 실패 원인 분포 (G3) — 어디가 왜 깨지나
SELECT data->>'step' AS step, data->>'reason' AS reason, count(*)
FROM app_logs WHERE tag='funnel' AND data->>'result'='fail' AND ts > now()-interval '$WIN'
GROUP BY 1,2 ORDER BY 3 DESC;

-- D3) 온보딩 드롭오프 (G1) — session 단위 (pre-auth 포함)
SELECT count(DISTINCT session_id) FILTER (WHERE data->>'step'='onboardingShown')  AS shown,
       count(DISTINCT session_id) FILTER (WHERE data->>'step'='onboardingStart')  AS started,
       count(DISTINCT session_id) FILTER (WHERE data->>'step'='onboardingFinish') AS finished
FROM app_logs WHERE tag='funnel' AND ts > now()-interval '$WIN';
```
+ G6: 스킬 쿼리3을 `split_part(message,' ',-1)` 등 message 접미사 파싱으로 교정(또는 uxTrack을 `track` 스키마로 점진 이관).

---

## 6. 확인 필요 / 미확정

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | `APIError`의 case 목록 → `reasonTag` 매핑 | `APIClient.swift`의 `enum APIError` 정의 확인 (http status 보유 여부) |
| 2 | `performSync` 성공 종료 지점(단일 return인가) | `SyncService.swift` performSync 본문 |
| 3 | `appOpen` 단일 호출 위치 | `ScatchLMApp.swift` 진입 |
| 4 | onboardingShown를 session당 1회만 보장 | `.onAppear` 재호출 시 중복 — `@State firstAppear` 가드 |

---

## 7. 단계 (Tracks)

```
Phase 1 (반나절, 위험 낮음) ─ 측정 켜기
   ├─ T1 헬퍼: track() + reasonClass() + APIError.reasonTag        [LogService.swift, APIClient.swift]
   ├─ T2 삽입: §4의 6 step (onboarding/feedback/upload/sync/noteCreate/appOpen)
   └─ T3 SQL: D1~D3을 check-prod-logs 스킬에 추가 + G6 교정
Phase 2 (데이터 1주 관측 후) ─ 안정화 착수
   └─ D1의 fail_pct·p95 최댓값 step부터 방향 1(안정화) 작업
```

**의존성:** T1 → T2(헬퍼 먼저). T3는 독립(스킬 문서). 빌드 검증: 실기기+시뮬레이터(CLAUDE.md 정책).

**작업량:** 작음 (순변경 ~40줄, 5개 파일 + 스킬 1). 기존 로그 유지라 회귀 위험 낮음.

---

## 8. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 선행 스펙 "산발 래핑 폐지"와 외관상 충돌 | 방향 혼선 | §0에서 명시 화해: 목표가 디버깅 인프라가 아니라 *제품 퍼널*, 범위는 고정 6 step |
| `funnel` 태그 이벤트가 Release 트래픽 비용 증가 | 경미 | 코어 루프 저빈도 이벤트만(렌더 로그 아님). debug 아닌 info/error라 의도된 전송 |
| `track` 도입 후 기존 funnel SQL(message 기반)과 이중 진실 | 운영 혼선 | Phase 1은 *병행*(기존 로그 유지). 안정화 후 SQL을 `data` 기반으로 일원화 |
| reason 분류가 실제 에러를 `unknown`으로 뭉갬 | 트리아지 정밀도↓ | D2에서 `unknown` 비중 모니터 → 큰 버킷이면 case 추가(반복 개선) |
| onboardingShown 중복(.onAppear 재호출) | 분모 과대 | §6-4 firstAppear 가드 |
