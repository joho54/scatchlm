# 심사 제출 전 체크리스트 (Pre-Submission Runbook)

> **전제:** 구현 트랙(A–H)은 코드로 완료됨. 이 문서는 "제출 버튼 직전"까지 밟는 **코드 외 수동 작업 + 검증** 순서다.
> **상위 문서:** 게이트 근거 `launch-readiness-spec.md` §3, 트랙 계약 `launch-readiness-implementation-spec.md` §8, 포털/배포 상세 `launch-app-store-connect.md`.
> **원칙:** 위에서 아래로 순서대로. 각 단계는 다음 단계의 전제다. 한 줄이라도 ❌면 제출하지 않는다.

---

## Phase 0 — 코드 in-place 확인 (완료됨, 1회 재확인)

심사 차단 3종이 실제 빌드에 들어갔는지 최종 확인. (2026-06-02 grep 확인 완료)

- [x] BE 계정삭제: `routers/account.py`, `services/account_deletion.py`, `services/supabase_admin.py`
- [x] BE quota/admin/CORS: `core/quota.py`, `auth.py`(`require_admin`/`app_metadata`), `main.py`(`ALLOWED_ORIGINS`)
- [x] BE 정적 약관: `backend/static/privacy.html`, `terms.html`
- [x] iOS Apple 로그인: `LoginView.swift`/`AuthService.swift` + `ScatchLM.entitlements`의 `com.apple.developer.applesignin`
- [x] iOS 계정삭제: `AuthService.deleteAccount` / `DatabaseService.purgeAllData` / `SettingsSheet`
- [x] 버전: `project.yml` `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=1`

---

## Phase 1 — 외부 인프라 설정 (포털, 리드타임 가장 김 → 먼저)

> 출처: `launch-app-store-connect.md` "D-2 사전 인프라". Apple/Supabase 설정은 전파에 시간이 걸리니 **가장 먼저**.

- [ ] **Apple Developer**: App ID에 **Sign in with Apple** capability 활성화. 자동 서명이 entitlements의 `com.apple.developer.applesignin`를 매칭하는지 확인.
- [ ] **Supabase → Authentication → Providers → Apple** 활성화: Service ID / Key(.p8) / Team ID 등록.
- [ ] **운영자 role 설정**: 운영자 유저 `app_metadata.role="admin"` (Supabase 대시보드/Admin API).
- [ ] **pro 베타 유저 tier**: 필요 시 `app_metadata.tier="pro"` 설정.
- [ ] role/tier 설정한 계정은 **재로그인**(토큰 refresh)해야 클레임 반영됨 — 확인.
- [ ] 심사용 **테스트 계정** 1개 준비 (Apple 또는 Google 로그인 가능, 샘플 데이터 약간 적재).

---

## Phase 2 — 프로덕션 백엔드 배포 (앱 제출 전 반드시 라이브)

> 출처: `launch-app-store-connect.md` "G-2". 출시 빌드가 가리키는 prod(`scatchlm.duckdns.org`)가 살아있어야 심사가 통과한다.

- [ ] 이미지 빌드/푸시:
  ```bash
  docker build --platform linux/amd64 -t ghcr.io/joho54/scatchlm-app:latest backend/
  docker push ghcr.io/joho54/scatchlm-app:latest
  ```
- [ ] `/opt/scatchlm/.env.prod`에 **신규 env** 주입:
  - [ ] `SUPABASE_SECRET_KEY` (신형 secret 키 = 옛 service_role; 계정 삭제 시 Supabase auth 유저 제거에 사용 — 없으면 삭제 502)
  - [ ] `DAILY_COST_LIMIT_NORMAL_USD` / `DAILY_COST_LIMIT_PRO_USD`
  - [ ] `ALLOWED_ORIGINS` (iOS 전용이면 빈 값 정상)
  - [ ] (관측) `APP_VERSION` / `GIT_SHA` / `ENVIRONMENT=prod`
- [ ] 정적 약관 동기화: `backend/static/{privacy,terms}.html` → VM `/opt/scatchlm/static/` (compose가 `./static:/srv/static:ro` 마운트).
- [ ] 배포:
  ```bash
  cd /opt/scatchlm
  docker compose -f docker-compose.prod.yml --env-file .env.prod pull
  docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
  ```
- [ ] DB 마이그레이션 (Track H — `page_guides` 언어 컬럼):
  ```bash
  docker compose -f docker-compose.prod.yml exec app alembic upgrade head
  ```
- [ ] **prod 검증** (전부 통과해야 다음 단계):
  - [ ] `curl https://scatchlm.duckdns.org/health` → `{"status":"ok","db":"ok","storage":"ok"}`
  - [ ] `curl -I https://scatchlm.duckdns.org/privacy` → 200, `/terms` → 200 (App Store Connect URL과 동일)
  - [ ] 응답 헤더에 `X-Request-Id` 존재
  - [ ] 계정 삭제 e2e (테스트 유저): DB·blob 0건 + Supabase 콘솔에서 유저 소거
  - [ ] admin 아닌 유저로 `GET /api/admin/usage` → 403

---

## Phase 3 — 릴리스 빌드 & 실기기/TestFlight 스모크 테스트

> Config가 prod(`scatchlm.duckdns.org`)를 가리키는 **Release** 구성으로 검증. 시뮬레이터 아님 — 심사 차단 기능은 실기기 콜백이 필요.

- [ ] `ios-app/ScatchLM/Utilities/Config.swift`의 API 호스트가 **prod**인지 확인 (개발용 로컬 IP 아님).
- [ ] Release 빌드로 실기기 또는 TestFlight 설치.
- [ ] **Sign in with Apple** 실기기 콜백 1회 성공 (로그인 → 세션 생성).
- [ ] **계정 삭제** 실기기 e2e: 설정 → "계정 삭제" → 확인 → 재로그인 시 빈 상태, Supabase에 유저 없음.
- [ ] 설정 화면에서 **개인정보 처리방침 / 이용약관 링크** 열림 (prod URL 200).
- [ ] 핵심 루프 1회: 노트 생성 → 펜 드로잉 → AI 피드백 → 후속 채팅(KaTeX 수식/행렬 정상 렌더 확인).
- [ ] 교재 PDF 업로드 → 뷰어 → 페이지 가이드 (언어 전환 시 stale 아님 — Track H).
- [ ] quota 한도 도달 시 친화 메시지(429) 확인 (한도 낮춰 테스트).
- [ ] 오프라인/네트워크 끊김 시 무음 실패 아닌 alert/toast 확인.

---

## Phase 4 — App Store Connect 메타데이터

> 출처: `launch-app-store-connect.md` "G-3". 누락 시 제출 자체가 막히거나 리젝.

- [ ] 앱 이름/부제, 카테고리(교육), 키워드, 설명.
- [ ] 버전 `1.0.0` / 빌드 `1` 업로드 (Xcode Organizer → Archive → Distribute).
- [ ] **개인정보 처리방침 URL**: `https://scatchlm.duckdns.org/privacy` 등록 (Phase 2에서 200 확인됨).
- [ ] (선택) 이용약관 URL: `https://scatchlm.duckdns.org/terms`.
- [ ] **스크린샷**: 13" iPad Pro + 11" iPad — 홈 / 노트+피드백 / 교재 뷰어 / **설정(계정 삭제 보이게)**.
  - 참고: `docs/appstore-screenshots/` (제작물 위치)
- [ ] **App Privacy(데이터 수집 신고)**:
  - [ ] 이메일(계정) · 사용자 콘텐츠(노트/드로잉/교재) · 진단(로그) 수집 명시.
  - [ ] 손글씨 데이터가 **AI 처리(Anthropic)로 전송**됨 반영.
- [ ] **심사 노트(Review Notes)**:
  - [ ] 테스트 계정 제공 (로그인 방법 명시).
  - [ ] **계정 삭제 위치 안내**: 앱 → 홈 좌상단 톱니바퀴(설정) → "계정 삭제" 섹션 → 확인 다이얼로그. (Guideline 5.1.1(v) 충족)
  - [ ] Sign in with Apple 제공으로 **Guideline 4.8** 충족(Google과 병행) 명시.

---

## Phase 5 — 심사 규정 최종 대조 (제출 직전 마지막 게이트)

> `launch-readiness-spec.md` §3 의 3대 BLOCKER가 **앱 + 포털 양쪽에** 충족되는지 최종 확인.

- [ ] **5.1.1(v) 인앱 계정 삭제** — 앱에서 시작 가능(웹 이동만 아님), e2e 동작(Phase 3) ✅, 심사노트에 위치 안내(Phase 4) ✅.
- [ ] **4.8 Sign in with Apple** — 서드파티 로그인(Google)과 동등하게 제공, 실기기 동작(Phase 3) ✅.
- [ ] **개인정보 처리방침** — 앱 내 링크 + ASC URL, 둘 다 200 ✅.
- [ ] 권한 사용 설명(Info.plist) — 카메라/사진/마이크 미사용이라 불필요(PencilKit only), ATS 추가설정 불필요(HTTPS) — 재확인.
- [ ] 결제(IAP) 미포함 — tier는 수동 부여, self-serve 구독은 post-launch. ASC에 IAP 미신고 일치.

---

## Phase 6 — 제출

- [ ] 빌드 처리 완료(ASC에서 "처리 중" → 선택 가능) 확인.
- [ ] 위 Phase 0–5 전부 ✅.
- [ ] **Submit for Review.**

---

## 출시 직후 fast-follow (제출 차단 아님 — 별도 추적)

> `launch-readiness-implementation-spec.md` §8 "품질" + §1.3 Out of Scope. 제출과 무관하나 1차 릴리스 직후 우선순위.

- 크래시/에러 트래킹(Sentry, O7) 도입.
- 비즈니스 지표(DAU/MAU, 리텐션) 파이프라인.
- 접근성(VoiceOver/Dynamic Type) 점검.
- 결제(IAP) self-serve pro 업그레이드 — 별도 spec + 별도 심사.
- 커스텀 런치스크린/온보딩.
