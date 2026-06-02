# 심사 제출 전 체크리스트 (Pre-Submission Runbook)

> **출시 범위:** v1 = **무료 단독 출시.** 구독(IAP)은 코드 완성돼 있으나 **피처플래그(`Config.subscriptionEnabled=false`)로 숨김** → 사업자등록·세금 정리 후 **fast-follow로 켬**(맨 아래 섹션).
> **결정 배경:** 한국 개인 셀러의 유료 앱 계약이 사업자등록(NTS 증명서)을 요구 → 출시를 막지 않기 위해 무료 먼저, 구독은 후속. (`iap-subscription-spec.md` §8 fallback)
> **상위 문서:** 게이트 `launch-readiness-spec.md` §3, 트랙 `launch-readiness-implementation-spec.md` §8, IAP `iap-subscription-spec.md`.
> **원칙:** 위→아래 순서. 한 줄이라도 ❌면 제출하지 않는다.

---

## Phase 0 — 코드 in-place (완료)

- [x] BE 계정삭제 / quota / admin가드 / 정적 약관(`privacy.html`·`terms.html`)
- [x] iOS Apple 로그인 + 계정삭제(`deleteAccount`/`purgeAllData`)
- [x] **구독 UI 게이팅**: `Config.subscriptionEnabled=false` → SettingsSheet "구독" 섹션 숨김, 429→토스트, StoreKit start 미호출 (시뮬 빌드 성공·커밋 `586120d`)
- [x] 버전 `MARKETING_VERSION=1.0.0` / `CURRENT_PROJECT_VERSION=1`

---

## Phase 1 — 외부 인프라 (무료엔 최소)

- [x] **Apple Developer**: App ID `com.joho54.scatchlm`에 **Sign in with Apple** 활성화.
- [x] **Supabase Apple provider** + Authorized Client IDs `com.joho54.scatchlm` (네이티브 플로우).
- [x] **운영자 role**: `app_metadata.role="admin"` + 재로그인.
- [ ] 심사용 **테스트 계정** + 샘플 데이터(노트/피드백/교재).

> **무료 출시엔 유료 앱 계약·세금·은행 불필요** (무료 앱 계약 이미 Active). 진행 중이던 은행/계약은 구독 켤 때 마저.
> ⚠️ Google·Apple 동일 이메일도 Supabase는 **별개 유저**. 리뷰어엔 데이터 있는 provider 계정 안내.

---

## Phase 2 — 프로덕션 백엔드 (배포 = CI/CD)

- [x] **배포 자동화**: `main`에 `backend/**` 푸시 → `deploy.yml` 자동 빌드·VM 동기화·`up -d`·헬스체크.
- [x] **`.env.prod` env**: `SUPABASE_SECRET_KEY`(계정삭제), `DAILY_COST_LIMIT_NORMAL_USD=1.00`·`_PRO_USD=1.00` 적용·검증.
  - 무료 단독이라 모두 normal tier → **NORMAL=1.00(≈50건/일)은 abuse 천장**(정상 유저 안 닿음). *구독 켤 때 freemium $0.15로 하향.*
- [x] **마이그레이션**: head `588f1d04cd22` 적용 확인.
- [ ] **prod 검증**:
  - [x] `/health`=`{ok,db:ok,storage:ok}`, `/privacy`·`/terms` 200, `X-Request-Id` 헤더
  - [x] 계정 삭제 e2e → `supabase_auth_deleted:true` + 콘솔 유저 소거
  - [ ] admin role 계정 `GET /api/admin/usage` 200 / 비-admin 403

---

## Phase 3 — 릴리스 빌드 & 실기기 스모크

- [x] `Config.swift` Release → `https://scatchlm.duckdns.org/api` 분기.
- [ ] Release 빌드 실기기/TestFlight 설치.
- [x] Sign in with Apple 실기기 콜백.
- [x] 계정 삭제 실기기 e2e.
- [ ] **설정에 "구독" 섹션이 안 보이는지** 확인 (피처플래그 게이팅 검증).
- [ ] 설정에서 개인정보/약관 링크 열림.
- [ ] 핵심 루프: 노트→드로잉→AI 피드백→채팅 (**KaTeX 행렬/수식 정상**).
- [ ] 교재 PDF 업로드→뷰어→페이지 가이드 (언어 전환 stale 아님 — Track H).
- [ ] 오프라인 시 토스트(무음 실패 아님). *(~120초 후 토스트+스피너 해제 — 정상, 차단 아님.)*

---

## Phase 4 — App Store Connect 메타데이터 (무료)

- [ ] **앱 가격: 무료.** **IAP 상품 미제출.**
- [ ] 이름/부제/카테고리(교육)/키워드/설명. ⚠️ 부제를 "외국어"에 가두지 말 것 — 스크린샷(#6 ML/전공)이 **범용 학습**을 미므로 톤 일치.
- [ ] 버전 `1.0.0` / 빌드 `1` 업로드.
- [ ] **개인정보 URL** `…/privacy` (+ 선택 `…/terms`).
- [ ] **스크린샷**: `docs/appstore-screenshots/out/shot-1~7.png` (2048×2732, 상태바 정리됨) → iPad 13" 슬롯.
- [ ] **App Privacy**: Email(계정)·User Content(노트/드로잉/교재)·User ID·Diagnostics(로그) — 전부 Linked, App Functionality, **Tracking=No**. (Purchases 항목 **없음** — IAP 미포함). 손글씨 AI(Anthropic) 전송은 privacy.html에 명시.
- [ ] **심사 노트**: 테스트 계정(로그인 방법) · **계정 삭제 위치**(홈 톱니→설정→계정 삭제, 5.1.1(v)) · Sign in with Apple(4.8). *(구독 관련 문구 없음)*

---

## Phase 5 — 심사 규정 최종 대조

- [ ] **5.1.1(v) 인앱 계정 삭제** — e2e ✅ + 심사노트 위치.
- [ ] **4.8 Sign in with Apple** — Google과 동등 제공, 실기기 동작.
- [ ] **개인정보 처리방침** — 앱 내 링크 + ASC URL 둘 다 200.
- [ ] **구독 UI 비노출** — `subscriptionEnabled=false`로 결제 진입점 없음 → 비작동 결제 UI 리젝(2.1/3.1.1) 리스크 제거. (IAP 미신고와 일치)
- [ ] 권한 설명(Info.plist) 불필요(PencilKit), ATS 불필요(HTTPS).

---

## Phase 6 — 제출

- [ ] 빌드 처리 완료(ASC 선택 가능).
- [ ] Phase 0–5 전부 ✅.
- [ ] **Submit for Review.**

---

## 출시 후 fast-follow ① — 구독(IAP) 켜기 (코드 완성, 설정·등록만)

> 사업자등록 정리되면 진행. 코드/Paywall 다 됨 → 아래는 전부 설정/포털.

1. **사업자등록** (홈택스, 개인사업자) → 사업자등록증. (홈택스 신청 운영시간 주의)
2. **유료 앱 계약** 활성화: 법인정보·세금(W-8BEN, 사업자번호+증명서)·은행 완료 → "활성화됨".
3. **ASC 구독 상품** `com.joho54.scatchlm.pro.monthly` ₩9,900/월 생성 → 앱 **Apple ID(숫자)** 확보.
4. **prod `.env.prod`**: `APPLE_APP_APPLE_ID=<숫자>` 추가, `DAILY_COST_LIMIT_NORMAL_USD`를 **0.15로 하향**(freemium) → `up -d`.
5. **ASSN v2 웹훅** URL(Prod+Sandbox): `https://scatchlm.duckdns.org/api/iap/notifications`.
6. **iOS**: `Config.subscriptionEnabled=true` → 빌드/제출. (구독 상품을 그 버전과 함께 제출, Paywall 3.1.2 충족 확인됨)
7. 샌드박스 e2e: 구매→pro→복원→만료(웹훅).

## 출시 후 fast-follow ② — 운영/품질

- COGS 모니터링 (`iap-spec` §10.5.1 SQL, pro 손익분기 ~10건/일).
- Sentry(O7) · 비즈니스 지표(DAU/MAU) · 접근성(VoiceOver/Dynamic Type) · 커스텀 런치스크린/온보딩.
