# Launch Readiness Spec: 출시 전 필수 기능 점검

> **Status:** Draft
> **Date:** 2026-06-02
> **Author:** (auto-generated)
> **Scope:** ScatchLM iOS 앱 + 백엔드의 App Store 출시 준비도 점검 및 잔여 작업 정의

---

## 1. Background

ScatchLM(펜 드로잉 외국어 학습 iPad 앱)의 핵심 기능은 대부분 구현 완료 상태다.
이 문서는 **출시(App Store 제출) 전 반드시 필요한 항목**을 코드 기준으로 점검하고,
누락분의 잔여 작업과 우선순위를 정의한다.

본 점검은 실제 코드 검증에 기반한다(파일·라인 인용). 범례:
- ✅ 구현됨
- ⚠️ 존재하나 리스크/미완 (배포·설정·정책 보강 필요)
- ❌ 없음
- ❓ 미점검 (후속 확인 필요)

관련 문서: 클라우드 동기화 `docs/cloud-data-sync-spec.md`, 배포 `backend/DEPLOY.md`, 전체 명세 `SPEC.md`

---

## 2. 핵심 기능 점검 (A)

대부분 완비. 동기화는 코드 완료·프로덕션 미배포.

| 기능 | 상태 | 근거 |
|---|---|---|
| 인증 (이메일/비번, Google OAuth, 세션 복원, 로그아웃) | ✅ | `AuthService.swift` (signIn/signUp/signInWithGoogle:52/signOut), `LoginView.swift` |
| 노트 CRUD (생성/목록/편집/삭제) | ✅ | `HomeView.swift`, `CreateNoteSheet`/`EditNoteSheet`, `DatabaseService` |
| 펜 드로잉 (PencilKit, 멀티 페이지, 페이지 네비) | ✅ | `NoteView.swift`, `PageNavigatorView.swift` |
| AI 손글씨 피드백 (캔버스→Vision→카드, 평가) | ✅ | `POST /api/feedback`, `FeedbackRatingSheet` |
| 피드백 후속 채팅 + RAG (교재 검색) | ✅ | `FeedbackChatSheet.swift`, `POST /api/feedback/chat` |
| PDF 교재 (업로드/뷰어/페이지·챕터 가이드) | ✅ | `PdfViewerView.swift`, `routers/pdf.py` |
| 클라우드 동기화 + 유저별 격리 | ✅ 코드 / ⚠️ prod 미배포 | `docs/cloud-data-sync-spec.md`, `SyncService.swift`, 백엔드 `/api/sync/*` |

---

## 3. App Store 심사 필수 — ❌ 누락 (제출 차단, 최우선)

계정 생성·외부 로그인·데이터 수집을 하는 앱이므로 아래 3건은 심사에서 거의 확실히 막힌다.

### 3.1 계정 삭제 (인앱) — 🔴 BLOCKER
- **현황:** `SettingsSheet.swift`에 Feedback Language / 수식 렌더링 / Sign Out / Done만 존재. 계정 삭제 없음.
- **근거:** Apple App Store Review Guideline **5.1.1(v)** — 계정 생성을 지원하는 앱은 **인앱 계정 삭제**를 제공해야 한다(설정 깊은 곳의 링크/웹 이동만으로는 불충분, 앱 내에서 시작 가능해야 함).
- **필요 작업:**
  - iOS: 설정에 "계정 삭제" 진입점 + 확인 다이얼로그.
  - 백엔드: `DELETE /api/account` (현재 유저의 users·ai_response·llm_usage·textbook_sources·sync 4테이블·blob 전부 삭제) + Supabase Auth 유저 삭제(admin API).
  - 로컬: 삭제 후 로컬 DB의 해당 user_id 행 정리 + 세션 종료.

### 3.2 Sign in with Apple — 🔴 BLOCKER 가능성 높음
- **현황:** 이메일/비번 + Google OAuth(`AuthService.signInWithGoogle:52`). Sign in with Apple 없음.
- **근거:** Guideline **4.8** — 제3자 소셜 로그인(Google)을 제공하면, 데이터 수집을 이름·이메일로 한정하고 이메일 비공개를 지원하는 동등 옵션을 함께 제공해야 한다. 이메일/비번 로그인이 대안으로 인정될 여지는 있으나 **불확실**. Sign in with Apple 추가가 안전.
- **필요 작업:** `ASAuthorizationAppleIDButton` + Supabase Apple provider 연동. (Apple Developer에 Sign in with Apple capability·키 설정 필요.)

### 3.3 개인정보 처리방침 / 이용약관 — 🔴 BLOCKER
- **현황:** 앱 내 정책/약관 링크 없음. App Store Connect 메타데이터에도 URL 필요.
- **근거:** 데이터 수집·계정 앱은 개인정보 처리방침 URL 필수. 미국·EU 외 한국 출시 시 약관도 권장.
- **필요 작업:** 정책/약관 문서 작성 + 호스팅(예: `scatchlm.duckdns.org/privacy`) → 설정 화면 링크 + App Store Connect 등록.

---

## 4. 보안 · 운영 — ⚠️ 출시 전 보강

| 항목 | 상태 | 근거 / 작업 |
|---|---|---|
| CORS 와일드카드 | ⚠️ | `app/main.py:14` `allow_origins=["*"]` (TODO 그대로). iOS 전용 API이므로 도메인 화이트리스트 또는 제거 |
| LLM 사용량 제한 | ⚠️ | `LLMUsage`(`models/usage.py`)는 **기록만**(`feedback.py:137,154`), quota/rate limit **미적용** → 비용 폭주·악용 위험. 일일/유저별 한도 또는 rate limit 도입 |
| 클라우드 동기화 프로덕션 배포 | ❌ | 백엔드 이미지 재빌드/푸시 + 프로덕션 DB `alembic upgrade head`. 미배포 시 sync가 offline/error로 표시되고 클라우드 저장 미작동 |
| DB 초기화 `fatalError` | ⚠️ | `DatabaseService.swift` init — 마이그레이션 실패 시 즉시 크래시. 복구/안내 경로 검토 |
| 토큰/시크릿 관리 | ❓ | `.env` 커밋 금지 준수 여부, Supabase anon key·API 호스트(`Config.swift`) 운영 값 확인 |

---

## 5. UX 완성도 — 점검 완료 (코드 검증)

### 5.1 에러 처리 — ⚠️ 부분 (무음 실패 다수)

| 화면 | 실패 시 알림 | 근거 |
|---|---|---|
| 로그인 | ✅ alert | `LoginView.swift:32-35` |
| PDF 가이드 로드 | ✅ 텍스트 안내 | `PdfViewerView.swift:286-288,481-483` |
| **AI 피드백 요청** | ❌ 로그만 (무음) | `NoteView.swift:806` `appLogError`만 |
| **피드백 후속 채팅** | ❌ 로그만 (무음) | `FeedbackChatSheet.swift:303` |
| **노트 CRUD** | ❌ 로그만 (무음) | `HomeView.swift:91,108,123,132` |

- `APIError`(`APIClient.swift`)는 `"Server error 500: ..."` 식 기술 메시지 — 사용자 친화 문구·로컬라이즈 없음.

### 5.2 데이터 정합성 — 🔴 `try?`로 DB 저장 실패 삼킴

DB 저장 실패 시에도 UI(메모리 배열)에는 추가되어 **앱 재시작 시 데이터 유실/불일치** 가능. dirty 기반 sync에도 안 잡힘.

| 파일:라인 | 작업 |
|---|---|
| `NoteView.swift:488,507` | `try? db.saveFeedback` (피드백 카드) |
| `NoteView.swift:551` | `try? db.savePageDrawing` (드로잉 본문) |
| `FeedbackChatSheet.swift:231,296` | `try? db.saveChatMessage` (채팅) |

→ 저장 실패 시 UI 롤백 또는 사용자 알림 필요.

### 5.3 로딩 상태 — ✅ 대체로 양호

- ✅ 피드백 생성(`NoteView.swift:384-387` FAB 스피너), 가이드(`PdfViewerView:222`), 채팅(`FeedbackChatSheet:49`), 노트 로드(`NoteView:156`).
- ❌ **PDF 다운로드 진행 표시 없음**(`NoteView.swift:820-844`) — 대용량 교재 시 60초 타임아웃까지 먹통처럼 보임.

### 5.4 빈 상태(Empty State) — ❌ 없음

노트 0개(HomeView), 피드백 0개(NoteView), 채팅 0개(FeedbackChatSheet) 모두 안내 문구 없이 빈 화면. 첫 사용자 혼란.

### 5.5 오프라인 — ⚠️ 부분

- ✅ sync는 `SyncService`(NWPathMonitor)+`SyncStatusIndicator`로 커버.
- ❌ 일반 API(피드백/채팅/가이드)는 네트워크 상태 체크 없음. `APIClient`는 `waitsForConnectivity=true`+60초 타임아웃이라 오프라인 시 긴 대기 후 무음 실패. `FeedbackChatSheet:282`는 별도 URLSession을 만들어 APIClient 설정조차 우회.

### 5.6 에셋 · 첫 실행 — 일부 보강 필요

| 항목 | 상태 | 근거 |
|---|---|---|
| 앱 아이콘 | ✅ 실제 1024 png | `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` |
| 런치스크린 | ⚠️ 자동 생성(커스텀 없음) | `project.yml` `UILaunchScreen_Generation: true` |
| 온보딩/첫 실행 | ❌ 없음 | 로그인 후 바로 HomeView(빈 화면) |
| 앱 버전/빌드 번호 | ⚠️ 미설정(Xcode 기본 1.0/1) | `project.yml`에 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 없음 — 제출 전 명시 권장 |
| **Google OAuth URL scheme** | ✅ **문제 없음** | `ASWebAuthenticationSession`(callbackURLScheme 자체 가로챔), `onOpenURL`/`CFBundleURLTypes` 불필요. 단 실기기 콜백 1회 확인 권장 |
| 권한 설명(Info.plist) | ✅ 불필요 | 카메라/사진/마이크 미사용(PencilKit only), HTTPS라 ATS 추가 설정 불필요 |
| 접근성(VoiceOver/Dynamic Type) | ❓ 미점검 | 후속 |

---

## 6. 잔여 작업 우선순위 (Tracks)

```
출시 차단(심사) ─── L1: 계정 삭제(인앱) + 백엔드 DELETE /api/account
                ├── L2: 개인정보 처리방침/약관 문서 + 링크 + ASC 등록
                └── L3: Sign in with Apple (Supabase Apple provider)

운영/비용 ──────── L4: sync 프로덕션 배포 (이미지 + prod 마이그레이션)
                ├── L5: LLM 사용량 quota/rate limit
                └── L6: CORS 도메인 제한

데이터/품질 ─────── L7: try? DB 저장 실패 롤백/알림 (데이터 정합성)
                ├── L8: API 실패 alert/toast + 에러 문구
                ├── L9: 빈 상태 UI + PDF 다운로드 로딩
                └── L10: 버전/빌드 번호 + (선택) 온보딩

관측성(§9) ─────── O1: admin 권한 가드(🔴) · O2: 로그 로테이션 · O3: 비용 알림
                └── O4: health 체크 · O5: 요청 로깅/예외 핸들러 · O6~O8: 클라로그·Sentry·sync지표
```

| ID | 영역 | 작업 | 차단도 |
|---|---|---|---|
| L1 | iOS+BE | 인앱 계정 삭제 + `DELETE /api/account`(전 데이터·blob·Supabase 유저 삭제) | 🔴 심사 |
| L2 | 문서+iOS | 개인정보 처리방침·약관 작성·호스팅 + 설정 링크 + App Store Connect URL | 🔴 심사 |
| L3 | iOS+Auth | Sign in with Apple 연동 | 🔴 심사(가능성 높음) |
| L4 | BE/배포 | 클라우드 sync 프로덕션 배포 + prod DB 마이그레이션 | 🟠 기능 |
| L5 | BE | LLM 사용량 한도/rate limit | 🟠 비용 |
| L6 | BE | CORS 허용 도메인 제한 | 🟠 보안 |
| L7 | iOS | **데이터 정합성**: `try?` DB 저장 실패 시 롤백/알림 (§5.2) | 🟠 데이터 |
| L8 | iOS | 피드백/채팅/CRUD 실패 시 alert·toast (§5.1) + APIError 사용자 문구 | 🟡 품질 |
| L9 | iOS | 빈 상태 UI(노트/피드백/채팅 0개) + PDF 다운로드 로딩·타임아웃 (§5.3-5.4) | 🟡 품질 |
| L10 | iOS | 앱 버전/빌드 번호 명시, (선택) 첫 실행 안내·커스텀 런치스크린 (§5.6) | 🟡 출시메타 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 계정 삭제 부재로 심사 리젝 | 높 | L1 최우선. 인앱 진입점 필수 |
| Sign in with Apple 부재로 4.8 리젝 | 중~높 | L3. 이메일/비번이 대안 인정될 수도 있으나 리스크 회피 권장 |
| LLM 비용 폭주(무제한 호출) | 중 | L5 유저별 일일 한도 + rate limit |
| sync 미배포 상태로 출시 → 멀티 디바이스 미작동 | 중 | L4 배포를 출시 체크리스트에 포함 |
| CORS 와일드카드 | 낮(인증 게이트됨) | L6 도메인 제한 |
| `/api/admin/usage` 권한 부재 → 타 유저 사용량·비용 노출 | 높 | O1 admin 가드 신설 |
| 로그 파일 무제한 증가 → 디스크 풀(10GB)로 서비스 중단 | 중 | O2 로테이션/보존 정책 |
| 장애 가시성 부재(예외 핸들러·에러 트래킹 없음) | 중 | O5/O7 미들웨어+Sentry |

---

## 8. 확인 완료 사항 (코드 검증)

1. **계정 삭제·약관·Sign in with Apple 부재** — `SettingsSheet.swift`(언어/렌더/Sign Out/Done만), `AuthService.swift`(이메일·Google만, Apple 없음), 앱 내 privacy/terms 링크 grep 결과 없음.
2. **CORS 와일드카드** — `backend/app/main.py:14` `allow_origins=["*"]` TODO 미해결.
3. **LLM 사용량 미강제** — `models/usage.py` 기록 전용, `routers/feedback.py:137,154`에서 적재만, 한도 체크 코드 없음.
4. **모든 로컬 write가 sync 커버** — 외부 직접 DB 쓰기 0건, 앱 write 14개 전부 `dirty=1`+`notifyWrite()`(별도 검증). 동기화 데이터 누락 없음.
5. **sync 프로덕션 미배포** — dev DB만 `alembic upgrade head` 적용, prod 미적용.
6. **무음 실패** — 피드백 요청(`NoteView.swift:806`)·채팅(`FeedbackChatSheet.swift:303`)·노트 CRUD(`HomeView.swift:108,123,132`) 실패가 로그만 남고 사용자 미고지.
7. **`try?` DB 저장 삼킴** — `NoteView.swift:488,507,551`, `FeedbackChatSheet.swift:231,296`에서 저장 실패해도 UI엔 반영 → 재시작 시 유실 가능.
8. **OAuth URL scheme은 비차단(오탐 정정)** — `ASWebAuthenticationSession` 사용으로 `CFBundleURLTypes` 불필요. `onOpenURL` 핸들러 부재 확인.
9. **앱 아이콘 존재** — `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` 실재. 버전/빌드 번호는 `project.yml` 미설정.

---

## 9. 로깅 · 모니터링 · 운용 지표 (Observability)

### 9.1 운용에 필요한 지표 체크리스트

프로덕션 운영·비용 통제·장애 대응에 필요한 항목과 현황:

| 분류 | 필요 지표/기능 | 현황 | 근거 |
|---|---|---|---|
| **LLM 비용** | 요청별 토큰/비용/지연 | ✅ | `models/usage.py` `LLMUsage`(input/output/total_tokens, cost_usd, latency_ms, error) |
| | 모델별·유저별·기간별 집계 | ✅ | `GET /api/admin/usage` (summary/by_model/recent) |
| | 비용 급증·일일 예산 **알림** | ❌ | 알림/임계치 없음 |
| **요청 관측** | 액세스 로그(method/path/status/latency) | ⚠️ uvicorn 기본만 | 앱 레벨 구조화 요청 로깅 미들웨어 없음 (`main.py` CORS만) |
| | 상관관계 ID(request_id) 전파 | ⚠️ 부분 | `feedback.py:51,182` 클라 제공 request_id만, 서버 생성 correlation id·전역 전파 없음 |
| | 5xx/에러율 집계 | ❌ | 전역 예외 핸들러 없음 |
| **에러/크래시** | 백엔드 예외 캡처(Sentry 등) | ❌ | 의존성·연동 없음 |
| | iOS 크래시 리포팅 | ❌ | 없음 |
| | 클라 에러 로그 수집 | ⚠️ dev 전용 | `LogService`→`POST /api/dev/log/batch` |
| **헬스/가용성** | liveness/readiness(DB·스토리지 체크) | ⚠️ | `/health`(`main.py:27`) 정적 `{"status":"ok"}`, 의존성 미검사 |
| | 외부 업타임 모니터·알림 | ❌ | 인프라 레벨 미설정 |
| **로그 관리** | 로그 로테이션/보존 | ❌ | `logging.py` `FileHandler`(app.log/fe.log) 무제한 증가, uvicorn.log도 tee. **디스크 10GB 한계**(CLAUDE.md)와 충돌 위험 |
| | 구조화(JSON) 로그 | ❌ | plain text 포맷만 |
| | 중앙 집계(로그 수집기) | ❌ | VM 파일에만 적재 |
| **동기화 관측** | push/pull/blob 로그 | ✅ 기본 | `routers/sync.py` log.info(returned/applied/missing_blobs) |
| | conflict율·missing_blob율·sync 실패 집계 | ❌ | 로그만, 지표 집계 없음 |
| **비즈니스 지표** | DAU/MAU·가입·노트 생성·피드백 요청·리텐션 | ❌ | 이벤트/분석 파이프라인 없음 |

### 9.2 보안·정합성 결함 (관측성 관련) — 🔴/⚠️

- 🔴 **`/api/admin/usage` 권한 부재** — `_current_user: str = Depends(get_current_user_id)`만 걸려 **인증된 아무 유저나** 호출 가능하고, `user_id` 쿼리 파라미터로 **타 유저의 사용량·최근 요청(user_id/task_type/language)까지 조회** 가능. 코드베이스에 admin 역할/화이트리스트 정의 자체가 없음(`core/`, `models/user.py`). → admin 가드 신설 또는 운영 도구로 분리 필요.
- ⚠️ **`/api/dev/log/batch` 인증 없음** — `devlog.py` 엔드포인트 무인증 + `LogService`가 Authorization 헤더 미첨부 → 누구나 로그 적재 가능(노이즈/소량 DoS). FE 로그에 user_id도 없어 유저 상관관계 추적 불가. `/api/dev/*` 경로상 **dev 전용**으로 보이며, 릴리스 빌드에선 게이팅/샘플링/인증 필요.
- 🔴 **`LogService` flush 선-비움 손실** — `flush()`가 네트워크 전송 **전에** `queue = []`로 비우고 POST는 `Task`에서 비동기 실행, 실패 시 `catch {}`로 무시하고 **재큐잉하지 않음** → 네트워크가 한 번만 끊겨도 최대 `maxQueue`(50)개 로그가 **영구 소실**. "장애 시점일수록 로그가 더 잘 사라지는" 구조 → 모니터링 신뢰성 전제를 위배. (`LogService.swift`)
- 🔴 **`LogService` 스레드 안전성 부재** — `queue`를 enqueue(임의 스레드, 백그라운드 Task의 `appLogError` 등)와 flush(메인 `Timer`)에서 동시 변경하는데 lock/actor/serial queue가 없음 → 데이터 레이스·간헐 크래시 가능. (`LogService.swift`)
- ⚠️ **`LogService` 배치 오염** — `data: [String: Any]`에 JSON 직렬화 불가 값이 하나라도 있으면 `JSONSerialization.data`가 throw → 해당 배치(최대 50개) 통째로 drop.
- ⚠️ **클라 로그 유실(인메모리)·재시도 부재** — 큐가 인메모리뿐이라 앱 종료/크래시 시 유실, background 전환 시 강제 flush 훅 없음. SyncService와 달리 실패 재시도/백오프 없음. 릴리스 빌드에서도 항상 `print()` + 2초 주기 전송(게이팅 없음).
- ⚠️ **로그 PII** — FE 로그 `data` dict에 임의 값이 실릴 수 있어 사용자 콘텐츠가 평문 로그로 남을 여지. 마스킹/필드 화이트리스트 검토.

### 9.3 권장 작업 (Observability 트랙)

| ID | 영역 | 작업 | 차단도 |
|---|---|---|---|
| O1 | BE | `/api/admin/usage` admin 권한 가드(역할/화이트리스트) — 사용량 데이터 노출 차단 | 🔴 보안 |
| O2 | BE/운영 | 로그 로테이션(RotatingFileHandler/logrotate) + 보존 정책 — 디스크 풀 방지 | 🟠 운영 |
| O3 | BE | LLM 일일/유저 비용 임계치 알림(§4 L5와 연계) | 🟠 비용 |
| O4 | BE | `/health` 의존성 체크(DB·스토리지)로 readiness화 + 외부 업타임 모니터 | 🟠 가용성 |
| O5 | BE | 요청 로깅 미들웨어(서버 생성 request_id·status·latency·user_id) + 전역 예외 핸들러 | 🟡 관측 |
| O6 | iOS | **`LogService` 신뢰성 개편(🔴)**: ① 전송 **성공 후** 큐 제거 + 실패 시 재큐잉/지수 backoff ② serial queue(또는 actor)로 enqueue/flush 직렬화 ③ 직렬화 불가 값 사전 sanitize(배치 오염 방지) ④ background/terminate flush 훅 + 디스크 버퍼(앱 종료·크래시 유실 방지) ⑤ 릴리스 게이팅/샘플링 + Authorization·user_id 첨부 + release `print` 제거 | 🔴 신뢰성 |
| O7 | 양쪽 | 에러 트래킹(Sentry 등) + iOS 크래시 리포팅 도입 | 🟡 관측 |
| O8 | BE | sync conflict/missing_blob/실패율 지표화 (대시보드 확장) | 🟡 관측 |
