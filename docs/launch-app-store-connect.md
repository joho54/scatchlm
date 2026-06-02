# App Store Connect 제출 메타 & 배포 체크리스트 (Track G-2/G-3)

> 코드 외 **수동 작업**(포털·인프라) 모음. 구현 트랙(A–H)은 코드로 완료됨.

## G-3 — App Store Connect 메타데이터

- **앱 이름 / 부제**: ScatchLM — 손글씨 외국어 학습
- **카테고리**: 교육
- **버전/빌드**: `MARKETING_VERSION=1.0.0` / `CURRENT_PROJECT_VERSION=1` (project.yml에 설정됨)
- **개인정보 처리방침 URL**: `https://scatchlm.duckdns.org/privacy`
- **이용약관(EULA) URL**: `https://scatchlm.duckdns.org/terms`
- **스크린샷**: 13" iPad Pro / 11" iPad — 홈, 노트+피드백, 교재 뷰어, 설정(계정 삭제 보이게).
- **App Privacy(데이터 수집 신고)**:
  - 이메일(계정) · 사용자 콘텐츠(노트/드로잉/교재) · 진단(로그) 수집 명시.
  - 손글씨 데이터는 AI 처리(Anthropic) 전송됨을 반영.
- **심사 노트(Review Notes)**:
  - 로그인: Sign in with Apple 또는 Google. 테스트 계정 제공.
  - **계정 삭제 위치**: 앱 실행 → 홈 좌상단 톱니바퀴(설정) → "계정 삭제" 섹션 → 확인 다이얼로그.
    (Guideline 5.1.1(v) 인앱 계정 삭제 충족.)
  - Sign in with Apple 제공으로 Guideline 4.8 충족(서드파티 로그인 Google과 병행).

## D-2 사전 인프라 (Apple 로그인)

- Apple Developer: App ID에 **Sign in with Apple** capability 활성화(자동 서명이 `ScatchLM.entitlements`의 `com.apple.developer.applesignin`를 매칭).
- Supabase: Authentication → Providers → **Apple** 활성화. Service ID / Key(.p8) / Team ID 등록.
- role/tier 운영자 설정: 운영자 유저 `app_metadata.role="admin"`, pro 베타 유저 `app_metadata.tier="pro"`를 Supabase 대시보드/Admin API로 1회 설정 후 **재로그인**(토큰 refresh).

## G-2 — 프로덕션 배포 체크리스트

1. 로컬 이미지 빌드/푸시:
   ```bash
   docker build --platform linux/amd64 -t ghcr.io/joho54/scatchlm-app:latest backend/
   docker push ghcr.io/joho54/scatchlm-app:latest
   ```
2. VM `/opt/scatchlm/.env.prod`에 **신규 env 3종** 주입(체크):
   - `SUPABASE_SERVICE_ROLE_KEY` (계정 삭제 필수)
   - `DAILY_COST_LIMIT_NORMAL_USD` / `DAILY_COST_LIMIT_PRO_USD`
   - `ALLOWED_ORIGINS` (iOS 전용이면 빈 값)
   - (관측) `APP_VERSION` / `GIT_SHA` / `ENVIRONMENT=prod`
3. 정적 약관 파일 동기화: `backend/static/{privacy,terms}.html` → VM `/opt/scatchlm/static/`.
   `docker-compose.prod.yml`이 `./static:/srv/static:ro`로 마운트.
4. 배포:
   ```bash
   cd /opt/scatchlm
   docker compose -f docker-compose.prod.yml --env-file .env.prod pull
   docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
   ```
5. **DB 마이그레이션**(Track H — `page_guides` 언어 컬럼):
   ```bash
   docker compose -f docker-compose.prod.yml exec app alembic upgrade head
   ```
6. 검증:
   - `curl https://scatchlm.duckdns.org/health` → `{"status":"ok","db":"ok","storage":"ok"}`
   - `curl -I https://scatchlm.duckdns.org/privacy` → 200, `/terms` → 200
   - 응답 헤더에 `X-Request-Id` 존재.
   - 계정 삭제 e2e(테스트 유저), admin 아닌 유저로 `/api/admin/usage` 403.
