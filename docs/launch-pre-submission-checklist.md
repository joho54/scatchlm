# 심사 제출 전 체크리스트 (Pre-Submission Runbook)

> **전제:** 구현 트랙(A–H + IAP)은 **코드로 완료됨**. 이 문서는 "제출 버튼 직전"까지 밟는 **코드 외 수동 작업 + 검증** 순서다.
> **출시 범위:** v1에 **freemium 구독(IAP) 포함** (normal 무료 + pro 월 구독). 근거·가격 `iap-subscription-spec.md` §10.
> **상위 문서:** 게이트 `launch-readiness-spec.md` §3, 트랙 `launch-readiness-implementation-spec.md` §8, IAP `iap-subscription-spec.md`, 포털/배포 `launch-app-store-connect.md`.
> **원칙:** 위에서 아래로. 각 단계는 다음의 전제다. 한 줄이라도 ❌면 제출하지 않는다.

---

## Phase 0 — 코드 in-place 확인 (완료됨)

- [x] BE 계정삭제: `routers/account.py`, `services/account_deletion.py`, `services/supabase_admin.py`
- [x] BE quota/admin/CORS: `core/quota.py`, `auth.py`(`require_admin`/`get_tier`), `main.py`(`ALLOWED_ORIGINS`)
- [x] BE 정적 약관: `backend/static/privacy.html`, `terms.html`
- [x] BE IAP: `routers/iap.py`, `services/apple_iap.py`, `iap_service.py`, `supabase_admin.set_app_metadata` (prod `/api/iap/*` 401=live)
- [x] iOS Apple 로그인: `LoginView`/`AuthService` + `applesignin` entitlement
- [x] iOS 계정삭제: `AuthService.deleteAccount` / `DatabaseService.purgeAllData` / `SettingsSheet`
- [x] iOS IAP: `StoreKitService.swift`, `PaywallView.swift`(심사요건 충족: 가격·자동갱신 고지·복원·약관/개인정보 링크), SettingsSheet "구독" 섹션, `Config.proMonthlyProductID`
- [x] 버전: `project.yml` `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=1`

---

## Phase 1 — 외부 인프라 / 계약 (리드타임 김 → 먼저)

- [x] **Apple Developer**: App ID `com.joho54.scatchlm`에 **Sign in with Apple** 활성화. (In-App Purchase는 별도 entitlement 키 불필요 — App ID capability + 자동서명이 처리.)
- [x] **Supabase → Auth → Providers → Apple** 활성화 + **Authorized Client IDs에 `com.joho54.scatchlm`**(네이티브 id token의 audience). Service ID/.p8는 **네이티브 플로우라 불필요**.
- [x] **운영자 role**: `app_metadata.role="admin"` (SQL Editor) + 재로그인.
- [ ] **Apple 유료 앱 계약(Paid Apps Agreement)** 체결 + 은행·세금 정보 — **구독(IAP)의 절대 선행조건**. 미체결 시 IAP 생성·판매 불가.
- [ ] (권장) **Small Business Program** 가입 → 수수료 15% (`iap-spec` §10.2 전제).
- [ ] 심사용 **테스트 계정** + 샘플 데이터(노트/피드백/교재). 구독 테스트용 **샌드박스 테스터**는 Phase 2B.

> ⚠️ Google·Apple 동일 이메일이라도 Supabase는 **별개 유저**(자동 링크 폐지). 심사 리뷰어에겐 **데이터가 들어있는 provider** 계정으로 안내. (UX 엣지, 출시 차단 아님)

---

## Phase 2 — 프로덕션 백엔드 (배포 = CI/CD)

> prod `scatchlm.duckdns.org`가 출시 코드로 라이브여야 심사 통과. 현재 출시 코드 배포·동작 확인됨.

- [x] **배포 자동화**: `main`에 `backend/**` 푸시 → `.github/workflows/deploy.yml`이 빌드·push·VM 동기화(compose/Caddyfile/static)·`up -d`·헬스체크. **수동 빌드/SSH 불필요.**
- [ ] **`/opt/scatchlm/.env.prod` 수동 env** (CI가 안 건드림 → 직접 편집 후 `up -d`):
  - [x] `SUPABASE_SECRET_KEY` (계정 삭제 시 auth 유저 제거 — 없으면 502). 설정·동작 확인됨.
  - [ ] `DAILY_COST_LIMIT_NORMAL_USD=0.15` / `DAILY_COST_LIMIT_PRO_USD=1.00` (freemium — `iap-spec` §10.4). **반드시 양수**(0이면 무제한 무료 = freemium 붕괴).
  - [ ] `APPLE_APP_APPLE_ID=<ASC 앱 Apple ID 숫자>` (프로덕션 IAP 웹훅 서명 검증용 — Phase 2B에서 앱 생성 후 채움).
  - [ ] (선택) `ALLOWED_ORIGINS`(네이티브라 빈 값 정상) · `APP_VERSION`/`GIT_SHA`/`ENVIRONMENT=prod`.
- [x] **DB 마이그레이션** (CI 자동 아님 — 수동): 현재 head `588f1d04cd22` 적용 확인 (Track H `page_guides` + IAP `iap_entitlements` 포함). 추후 모델 변경 시 `ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T app alembic upgrade head'`.
- [ ] **prod 검증**:
  - [x] `/health` → `{"status":"ok","db":"ok","storage":"ok"}`
  - [x] `/privacy`·`/terms` 200, 응답에 `X-Request-Id`
  - [x] 계정 삭제 e2e → `supabase_auth_deleted: true` + Supabase 콘솔 유저 소거
  - [ ] admin role 계정으로 `GET /api/admin/usage` 200 / 비-admin 403
  - [x] `/api/iap/status` 라우트 live (401 무인증)

---

## Phase 2B — 구독(IAP) 출시 활성화 (Track C, 코드 외)

> 코드는 완료. ASC 상품이 없으면 `Product.products(for:)`가 비어 Paywall이 아무것도 못 판다. **앱 빌드와 구독 상품을 함께 제출**해야 한다.

- [ ] **ASC: 자동갱신 구독** 그룹 생성 + 상품 **`com.joho54.scatchlm.pro.monthly`**, **₩9,900/월**, 로컬라이즈 이름/설명, 구독 심사용 스크린샷.
- [ ] ASC 앱 레코드의 **Apple ID(숫자)** 확인 → Phase 2 `.env.prod`의 `APPLE_APP_APPLE_ID`에 주입 + `up -d`.
- [ ] **ASSN v2 웹훅 URL 등록** (Production + Sandbox **각각**): `https://scatchlm.duckdns.org/api/iap/notifications`.
- [ ] **첫 제출 시 버전에 IAP 상품 선택** (빌드와 함께 심사 제출).
- [ ] 샌드박스 검증(Phase 3에서 실기기):
  - [ ] 샌드박스 테스터 계정 생성.
  - [ ] 구매 → `/api/iap/verify` 200(pro) → `refreshSession` → `/feedback`이 **pro 한도** 적용.
  - [ ] 앱 재설치 후 **구매 복원**으로 pro 복귀.
  - [ ] EXPIRED 웹훅(또는 샌드박스 갱신 만료) → tier=normal 동기화.

---

## Phase 3 — 릴리스 빌드 & 실기기 스모크

> Config가 prod를 가리키는 **Release** 구성. 시뮬레이터 아님(콜백·결제는 실기기/샌드박스 필요).

- [x] `Config.swift` API 호스트 — Release는 `https://scatchlm.duckdns.org/api`로 분기 확인.
- [ ] Release 빌드로 실기기/TestFlight 설치.
- [x] **Sign in with Apple** 실기기 콜백 성공.
- [x] **계정 삭제** 실기기 e2e (Supabase 유저 소거).
- [ ] 설정에서 **개인정보/약관 링크** 열림.
- [ ] 핵심 루프: 노트 → 드로잉 → AI 피드백 → 채팅 (**KaTeX 행렬/수식 정상 렌더**).
- [ ] 교재 PDF 업로드 → 뷰어 → 페이지 가이드 (언어 전환 시 stale 아님 — Track H).
- [ ] **구독 구매/복원** 샌드박스 e2e (Phase 2B) + quota 429 → **Paywall** 노출.
- [ ] 오프라인 시 무음 실패 아님(토스트). *(현 동작: ~120초 후 토스트+스피너 해제 — 정상. 차단 아님.)*

---

## Phase 4 — App Store Connect 메타데이터

- [ ] 앱 이름/부제/카테고리(교육)/키워드/설명. ⚠️ 부제를 "외국어"에 가두지 말 것 — 스크린샷(#6 ML/전공)이 **범용 학습**을 밀므로 톤 일치.
- [ ] 버전 `1.0.0` / 빌드 `1` 업로드 (Xcode Organizer → Archive → Distribute).
- [ ] **개인정보 URL** `…/privacy` 등록 (+ 선택 `…/terms`).
- [ ] **스크린샷**: `docs/appstore-screenshots/out/shot-1~7.png` (2048×2732, 상태바 정리됨) → iPad 13" 슬롯.
- [ ] **App Privacy(데이터 수집)**:
  - [ ] Contact Info→Email(계정) · User Content(노트/드로잉/교재) · Identifiers→User ID · Diagnostics(로그) — 전부 Linked, App Functionality, **Tracking=No**.
  - [ ] **Purchases→Purchase History** (구독 entitlement를 user_id로 저장) — Linked, App Functionality.
  - [ ] 손글씨가 **AI 처리(Anthropic) 전송**됨은 privacy.html에 명시 확인.
- [ ] **심사 노트**:
  - [ ] 테스트 계정(로그인 방법) + **구독 테스트(샌드박스) 방법·Pro 혜택**.
  - [ ] **계정 삭제 위치**: 홈 좌상단 톱니 → 설정 → "계정 삭제" → 확인 (Guideline 5.1.1(v)).
  - [ ] Sign in with Apple 제공 (Guideline 4.8).

---

## Phase 5 — 심사 규정 최종 대조

- [ ] **5.1.1(v) 인앱 계정 삭제** — 앱 내 시작, e2e ✅, 심사노트 위치 안내.
- [ ] **4.8 Sign in with Apple** — Google과 동등 제공, 실기기 동작.
- [ ] **개인정보 처리방침** — 앱 내 링크 + ASC URL 둘 다 200.
- [ ] **3.1.2 자동갱신 구독** — PaywallView 고지문(가격·기간·자동갱신)·복원·약관(EULA)/개인정보 링크 ✅(코드 확인됨) + **구독 상품을 빌드와 함께 제출** + 무료 tier로도 핵심 사용 가능(freemium).
- [ ] 권한 설명(Info.plist) 불필요(PencilKit only), ATS 불필요(HTTPS) — 재확인.

---

## Phase 6 — 제출

- [ ] 빌드 처리 완료(ASC 선택 가능).
- [ ] 버전에 **IAP 구독 상품 첨부** 확인.
- [ ] Phase 0–5 전부 ✅.
- [ ] **Submit for Review.**

---

## 출시 직후 fast-follow (제출 차단 아님)

- IAP: 정기 reconciliation 잡(App Store Server API), 연간/체험 플랜, Paywall 고도화 (`iap-spec` §8).
- COGS 모니터링: `iap-spec` §10.5.1 SQL로 pro 단위경제(손익분기 ~10건/일) 추적.
- 크래시/에러 트래킹(Sentry, O7) · 비즈니스 지표(DAU/MAU) · 접근성(VoiceOver/Dynamic Type) · 커스텀 런치스크린/온보딩.
