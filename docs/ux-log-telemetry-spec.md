# UX 로그(텔레메트리) 보강 Spec: 인터셉터 일괄 수정 한정

> **Status:** Draft
> **Date:** 2026-06-04
> **Author:** (auto-generated)

---

## 1. Background

### 1.1 운영 이력 / 현재 상태

FE 로그는 `LogService`가 2초 주기로 `POST /api/dev/log/batch`에 보내고, 백엔드 `devlog.py._emit`이 `[FE ts][trace][sess][u][rid][tag] message | data` 포맷으로 uvicorn 로그에 찍는다. 운영 로그 분석은 `/check-prod-logs`(grep 기반).

2026-06-04 운영 로그 조사(세션 `B94F6A89`, `u:66d2d3d1` = 테스터 `johoo54@naver.com`)에서 텔레메트리 사각지대가 드러났다:

- **인증 실패에 침묵**: `signIn(email:password:)`는 로깅 전무, Google OAuth 취소는 `handleGoogleSignIn`이 조용히 삼켜(`LoginView.swift:142-150`) `google oauth start`만 남았다.
- **1차 대응(완료)**: `uxTrack` 인터셉터(`LogService.swift`) 추가 + `AuthService` 인증 진입점 7개 통과 → `start/ok/cancel/fail + ms + domain/code` 일관 기록. **인증 한정**.

### 1.2 설계 원칙 — "인터셉터 일괄"만 인프라로 취급한다

이 스펙의 핵심 결정: **텔레메트리 인프라 작업은 "한 곳 고치면 전체에 적용되는" 인터셉터 일괄 수정으로 한정한다.** 흐름마다 호출부를 손으로 래핑하는 산발적 수정은 "구멍 막기를 캠페인으로 재포장"한 것에 불과해 작업 자체가 산발적으로 진행되고 ROI가 낮으므로 **인프라 과제에서 배제**한다.

검증된 사실:
- **HTTP는 이미 `APIClient`가 전수 관측**(`APIClient.swift:31-44`)한다. feedback/sync/pdf의 네트워크 부분은 이미 찍힌다. 호출부 래핑이 *추가*로 주는 건 비-HTTP 로컬 의미론(트리거 여부, 캡처 포함 latency, `no-new-strokes` 분기)뿐이고 그마저 대부분 중복이다.
- 따라서 인터셉터 일괄 수정에 해당하는 것은 **(B) 백엔드 포맷터 + (D) LogService context** 둘뿐이다. 이 둘만 본 스펙의 범위.

### 1.3 Out of Scope (폐지 항목 포함)

| 항목 | 이유 |
|---|---|
| **(폐지) feedback/sync/pdf의 `uxTrack` 래핑** | **산발적 호출부 수정** → 인프라 아님. HTTP는 APIClient가 이미 관측, 고유 가치는 2곳뿐이고 대부분 중복. 캠페인 sweep 폐지 |
| **(폐지) Google OAuth hang 타임아웃** | 단일 호출부 수정 + 동시성/시트 부작용 리스크. 이번 케이스는 테스터 본인이라 급하지 않음. 폐지 |
| `uxTrack`을 신규 사용자-액션 코드의 컨벤션화 | 인프라 작업이 아니라 **코딩 관례**(§4.3). 별도 sweep 없이 새 코드/기회주의적 적용으로 자연 증가 |
| 로그에 PII(이메일·이름) 기록 | 의도된 가명화(spec §3.2). 식별은 prefix→DB join |
| Sentry 통합 재활성화 | 별도 환경 이슈(메모리 `project_sentry_spm_deadlock`) |
| 로그 집계/대시보드 UI | grep 기반 운영 유지 |
| Supabase 대시보드 provider 설정 점검 | 인프라 설정 확인(코드 아님), 별건 |

> **폐지 결정 근거(2026-06-04):** 원안 Track A(iOS uxTrack 확장)·Track C(Google hang)는 호출부를 흐름마다 수정하는 산발적 작업으로, "인터셉터로 한방에"라는 본 작업의 전제와 모순됨. 인프라 범위에서 제외하고 B·D만 남김.

---

## 2. 현재 플로우 / 시스템 도식

```
[iOS] 사용자 액션
   ├─ HTTP 경유 ──────► APIClient (인터셉터: [api] →/← status, 비2xx throw) ✅ 전수 관측
   ├─ 인증(SDK 우회) ─► AuthService + uxTrack ✅ 1차 완료
   └─ 비-HTTP 로컬 ───► 산발 appLog  ◄── (폐지) 캠페인 대상 아님

[LogService] context: { user_id(전체 UUID), session_id, ... }   LogService.swift:68-78
   │  POST /api/dev/log/batch
   ▼
[Backend devlog.py._emit]   parts = [FE ts][trace][sess:8][u:8][rid][tag] msg|data
                                                  └ session_id[:8]  └ user_id[:8]  ◄── (B) 공백
   ▼
uvicorn.log → /check-prod-logs(grep) → [u:66d2d3d1] → DB join → email
```

본 스펙이 손대는 곳은 위 도식의 **두 박스**: `LogService.context`(D) 와 `devlog.py._emit`/스키마(B). 둘 다 단일 지점, 전체 로그에 일괄 적용.

---

## 3. API Contract Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | `/api/dev/log/batch` | FE 로그 배치 수신 | 변경 | §3.2-a |

### 3.2 변경 엔드포인트 계약 (동결)

```
### 3.2-a POST /api/dev/log/batch
- 변경점 1 (B, BE 전용 / 클라 무변경): user_id·session_id 절단폭 8 → 12.
    devlog.py:63  [sess:{session_id[:8]}]  → [:12]
    devlog.py:65  [u:{user_id[:8]}]        → [:12]
  근거: 8 hex = 32bit → 유저 증가 시 prefix 충돌 가능. 12 hex = 48bit로 실질 제거.
        전체 UUID는 이미 payload에 존재(LogService.swift:71) → 클라 변경 불필요.

- 변경점 2 (B+D): context.provider 신규 필드 + [prov:] 토큰.
    - Request context.provider: "apple"|"google"|"email"|null  (optional)
    - _emit: provider 있으면 [prov:{provider}] 토큰 추가, 없으면 생략(하위호환).
    - LogContext 스키마에 provider: str | None = None 추가 (devlog.py:24 블록).

- Response 200: { "received": <int> }   (현행 유지, devlog.py:51)
- Error: 422 — body 누락/스키마 불일치(Pydantic).
- 예시 (변경 후):
    [FE 2026-06-04T..Z] [sess:4E8D80F4xxxx] [u:66d2d3d1d71d] [prov:email] [ux] auth.email.signin ok | {'ms': 320}
- 하위호환: prefix 폭 변경은 grep 패턴([u:...])에 영향 없음. provider는 optional이라 구버전 클라/서버와 공존.
```

---

## 4. 구현 설계

### 4.1 (B) 백엔드 포맷터 — 단일 지점

`backend/app/routers/devlog.py`:
- `_emit`: `[:8]` → `[:12]` 2곳(line 63, 65). provider 있으면 `[prov:..]` 토큰을 `[u:..]` 뒤에 추가.
- `LogContext`: `provider: str | None = None` 필드 추가.

### 4.2 (D) provider 출처 — 단일 지점

`ios-app/ScatchLM/Services/LogService.swift` `context()`(line 68)에 `provider` 추가.
- 출처: `AuthService.shared`에 provider 노출 프로퍼티 추가 → `session.user`의 `appMetadata["provider"]` 또는 `identities` 마지막 provider. 미인증 시 null.
- AuthService 변경은 **단일 프로퍼티 추가**(호출부 수정 아님)라 인터셉터 원칙에 부합.
- §6.x: supabase-swift `User`의 provider 노출 경로 확인 필요.

### 4.3 (인프라 아님) uxTrack 컨벤션

`uxTrack`은 이미 존재한다. 별도 sweep 없이:
- **신규** 사용자-액션 코드는 `uxTrack(<도메인>.<액션>)`으로 감싸는 것을 기본 관례로 한다.
- **기존** 흐름은 다른 이유로 그 파일을 만질 때만 기회주의적으로 래핑.
- 이는 코드 리뷰 관례이지 본 스펙의 트랙(일정·배분 대상)이 아니다.

### 4.4 트리아지 절차 (문서)

prefix 12자리화 후 식별은 DB join이 정석:
```
[u:66d2d3d1d71d] → SELECT id,email,created_at FROM users WHERE id LIKE '66d2d3d1d71d%';
```
`/check-prod-logs` 스킬 노트 또는 CLAUDE.md에 1줄 추가(운영 메모).

---

## 5. 구현 단계 (Tracks)

```
시작 ──┬─── Track B: Backend — devlog.py 포맷터 + 스키마  [계약 §3.2-a 동결]
       │
       └─── Track D: iOS — LogService.context provider + AuthService provider 프로퍼티
```

**의존성:** 계약 §3.2-a 동결로 **B·D 완전 병렬**. D가 provider를 안 보내도 B는 토큰 생략 → 순서 무관. 둘 다 단일 지점 수정이라 트랙 내부 순차도 없음.

**작업량:** 전체 **작음** (순변경 ~15줄, 3개 파일). 위험 거의 0.

**인원별 배분:**
| 인원 | 배분 |
|---|---|
| 1명 | B → D (한 사람이 30분급) |
| 2명 | P1: B, P2: D (동시) |

### Track B: Backend — 로그 포맷터
**의존:** 없음 (계약 동결) · **작업량:** 작음
| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `backend/app/routers/devlog.py` | `[:8]`→`[:12]` (line 63, 65) + provider 있으면 `[prov:..]` 토큰 |
| B-2 | `backend/app/routers/devlog.py` | `LogContext`에 `provider: str | None = None` (line 24 블록) |

### Track D: iOS — provider 기록
**의존:** 없음 (B와 계약으로만 연결) · **작업량:** 작음
| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `ios-app/ScatchLM/Services/LogService.swift` | `context()`(68)에 `provider` 필드 추가 |
| D-2 | `ios-app/ScatchLM/Services/AuthService.swift` | provider 노출 프로퍼티 1개 추가(`session.user`에서). 호출부 수정 아님 |
| D-3 | (문서) `/check-prod-logs` 노트 또는 `CLAUDE.md` | prefix→DB join 트리아지 1줄 |

---

## 6. 확인 완료 사항 (코드 검증)

- 클라이언트는 **전체 lowercase UUID**를 `context.user_id`로 송신: `LogService.swift:71`(`AuthService.shared.syncUserId`). → prefix 절단은 **백엔드 책임**, 클라 무변경.
- prefix 8자리 절단 지점 확정: `devlog.py:63`(session_id), `:65`(user_id), 둘 다 `[:8]`.
- `LogContext` 스키마 위치/필드: `devlog.py:24-` (`user_id`, `session_id`, `app_version`, `build`, `os_version`, `device_model`, `locale`, `trace_id`).
- Response `{"received": len}`: `devlog.py:51`.
- APIClient가 모든 HTTP 인터셉트·비2xx throw: `APIClient.swift:31, 33-44`. → feedback/sync/pdf의 네트워크는 이미 관측됨(폐지 근거).
- `uxTrack`/`isUserCancel` 이미 존재 + 인증 7개 통과, 시뮬레이터 빌드 통과: `LogService.swift`, `AuthService.swift`.
- (폐지 대상이지만 참고) 산발 로그 현황: feedback `NoteView.swift:734~835`, sync `SyncService.swift:167`, pdf `PdfViewerView.swift:672~827`(12개). HTTP 외 고유 정보가 적어 ROI 낮음 → 폐지 타당.

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | supabase-swift `User`에서 provider 노출 경로 | `appMetadata["provider"]` vs `identities` — `.build/.../Auth/Types.swift` User 정의 확인 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| prefix 12자리화로 기존 grep 스크립트/스킬 문서 예시가 어긋남 | 운영 혼선(경미) | `[u:...]` 패턴 자체는 불변. 스킬 문서 예시만 갱신 |
| provider 필드가 구버전 클라/서버와 부정합 | 호환성 | 양측 optional(누락 시 토큰 생략) — §3.2-a 하위호환 |
| provider 출처(appMetadata vs identities)가 부정확 | 잘못된 라벨 | §6.x-1 확인 후 구현. 불확실하면 D-2 보류하고 B(prefix)만 선반영 |
| (폐지로 인한) feedback/sync 로컬 의미론 관측 공백 잔존 | 일부 디버깅 정보 부재 | 의도적 수용. 필요한 흐름은 §4.3 컨벤션으로 기회주의적 래핑 |
