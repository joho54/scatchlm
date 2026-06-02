# IAP 구독 (Freemium): normal(무료) → pro 자동갱신 구독 Spec

> **Status:** Draft
> **Date:** 2026-06-02
> **Author:** (auto-generated)
> **Scope:** iOS StoreKit 2 인앱 구독 + 백엔드 영수증 검증/entitlement 동기화. 하루부터 freemium(무료 tier 유지 + pro 구독).

---

## 1. Background

### 1.1 현재 상태 (substrate — 절반 깔려 있음)

`launch-readiness-implementation-spec.md §1.3`에서 IAP는 "대형 독립 트랙, post-launch 별도 spec"으로 빠졌다. 이 문서가 그 spec이다. 단가 구조상(피드백 건당 Sonnet ~$0.02–0.05, `feedback_service.py:60-62`) **성공=비례 출혈**이라 구독이 종착지로 합의됨. 일회성 유료는 COGS 미스매치로 배제.

이미 존재하는 기반:
- **tier 메커니즘:** `quota.py`가 `app_metadata.tier`(`normal`|`pro`)로 일일 비용 한도를 분기 (`DAILY_COST_LIMIT_{NORMAL,PRO}_USD`). 이미 동작.
- **tier 판정:** `auth.py:65-68` `get_tier(payload)` — **서명 검증된** JWT `app_metadata.tier`에서만 읽음.
- **service-role 클라이언트:** `supabase_admin.py` — httpx로 Supabase Admin REST 호출(현재 `delete_auth_user`만). `app_metadata` 설정 메서드만 추가하면 됨.
- **라우터 등록 패턴:** `main.py:12,37-42`.

없는 것(이 스펙의 작업):
- iOS StoreKit 2 구매/복원 플로우 (앱에 StoreKit 코드 0건 — grep 확인).
- 백엔드 Apple JWS 검증 + entitlement 영속 + tier 설정.
- Apple ASSN v2 웹훅(갱신·만료·환불 → tier 동기화).

### 1.2 핵심 아키텍처 결정 (전제 — §6에서 코드 근거)

**(1) tier는 JWT에 캐시된다 → flip은 eventually-consistent.**
quota가 `app_metadata.tier`를 **서명된 JWT**에서 읽으므로(`auth.py:67`), 백엔드가 Supabase `app_metadata.tier`를 바꿔도 **유저의 현재 토큰이 만료/refresh되기 전엔 반영 안 됨**.
- 구매 직후: 백엔드 검증 성공 → iOS가 **즉시 `refreshSession()`** 호출해야 새 JWT(tier=pro)를 받음.
- 만료/환불: 웹훅이 tier=normal로 내려도 유저 JWT는 만료(Supabase 기본 ~1h)까지 pro로 남음 → **최대 토큰 TTL만큼 lag**. 허용(§7).

**(2) 유저 매핑은 `appAccountToken`으로.**
StoreKit 구매 시 `Product.PurchaseOption.appAccountToken(<Supabase user UUID>)`를 심는다. Apple 서명 트랜잭션(JWS)과 ASSN 웹훅 payload 모두 이 토큰을 포함 → 백엔드가 **결제↔Supabase 유저**를 신뢰성 있게 매핑(서명 검증된 값이라 위조 불가).

**(3) entitlement 영속(table) — 백엔드가 source of truth.**
JWT tier는 *enforcement* 캐시일 뿐. 누락된 웹훅 복구·앱 시작 시 재동기화·감사·환불 추적을 위해 백엔드에 `iap_entitlements` 테이블을 둔다(§4.3). tier 설정은 항상 이 테이블 → `app_metadata` 순으로 반영.

### 1.3 Out of Scope

| 항목 | 이유 |
|---|---|
| 연간/다단계 플랜, 무료체험(intro offer), 프로모 코드 | 단일 월 구독으로 시작. 가격 데이터 후 확장 |
| Android/웹/Stripe 결제 | iOS 전용 출시. 디지털 구독은 Apple IAP 강제 |
| Family Sharing, 업/다운그레이드 proration | 단일 tier라 전환 없음 |
| grandfathering/가격 인상 정책 | 출시 후 |
| 서버측 App Store Server API 정기 reconciliation 잡(cron) | MVP는 앱 시작 시 + 웹훅 동기화. 정기 잡은 fast-follow |

---

## 2. 시스템 도식 (구매 → tier 반영)

```
iOS (StoreKit 2)                         Backend                          Apple
────────────────                         ───────                          ─────
SettingsSheet "Pro 구독"
   │ Product.purchase(
   │   appAccountToken: <supabase uid>) ──────────────────────────────────> App Store
   │ <─ Transaction(jwsRepresentation) ──────────────────────────────────── (signed)
   │
   ├─[verify]─> POST /api/iap/verify ──> JWS 서명검증(Apple root PKI)
   │            { signed_transaction }    productId·expiresDate·appAccountToken 추출
   │                                      → iap_entitlements upsert
   │                                      → supabase app_metadata.tier="pro"
   │ <─ 200 { tier:"pro", expires_at } ──┘
   │
   └─[refresh]─> AuthService.refreshSession()  ← 새 JWT(tier=pro) 발급
                    │
   이후 POST /api/feedback ─> quota.check_daily_quota(tier="pro")  ← pro 한도 적용

                              POST /api/iap/notifications <─ ASSN v2 (갱신/만료/환불)
                                 JWS 검증 → appAccountToken→user → tier 동기화
```

---

## 3. Backend API Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | `/api/iap/verify` | 구매 트랜잭션 검증 → tier=pro 설정 | **신규** | §3.2-a |
| POST | `/api/iap/notifications` | Apple ASSN v2 웹훅(갱신/만료/환불) | **신규** | §3.2-b |
| GET | `/api/iap/status` | 현재 entitlement 조회(복원·재동기화) | **신규** | §3.2-c |
| POST | `/api/feedback`, `/chat` | tier별 quota — **변경 없음**(이미 tier 분기) | 변경없음 | — |

### 3.2 신규 엔드포인트 계약 (동결)

#### 3.2-a POST /api/iap/verify  *(Track A)*
- **Request:**
  - header: `Authorization: Bearer <jwt>` (필수)
  - body: `{ "signed_transaction": string (StoreKit2 Transaction.jwsRepresentation, 필수) }`
- **동작:** JWS를 Apple root PKI로 **서명 검증** → payload에서 `bundleId`·`productId`·`appAccountToken`·`expiresDate`·`environment` 추출. 검증 통과 + `bundleId==com.joho54.scatchlm` + `appAccountToken==현재 user_id` 확인 → `iap_entitlements` upsert → 활성 구독이면 `app_metadata.tier="pro"`.
- **Response 200:**
  ```json
  { "tier": "pro", "product_id": "com.joho54.scatchlm.pro.monthly",
    "expires_at": "2026-07-02T10:00:00+00:00", "environment": "Sandbox" }
  ```
  (`tier`: `"pro"|"normal"`, `product_id`: string|null, `expires_at`: ISO8601|null, `environment`: `"Production"|"Sandbox"`)
- **Error:**
  - `401` — JWT 무효/만료.
  - `400` — JWS 서명 검증 실패 / bundleId 불일치 / 만료된 트랜잭션. `{"detail":"invalid transaction","code":"iap_invalid"}`
  - `409` — `appAccountToken != user_id` (타 계정 트랜잭션). `{"detail":"transaction belongs to another account","code":"iap_account_mismatch"}`
  - `502` — Apple/Supabase 호출 실패. `{"detail":"verification upstream failed"}`
- **빈/엣지:** 만료/환불된 트랜잭션이면 200 + `tier:"normal"`, `expires_at` 과거값. iOS는 이 경우 pro 미반영.
- **후속(iOS):** 200 & `tier=="pro"` → `AuthService.refreshSession()`로 새 JWT 수령(§4.2).
- **모킹:** iOS 단위 테스트는 `URLProtocol` 스텁으로 200(pro)/400/409 케이스.

#### 3.2-b POST /api/iap/notifications  *(Track A)*
- **Request:** **유저 인증 없음**(Apple→서버). body: `{ "signedPayload": string (ASSN v2 JWS, 필수) }`.
- **동작:** `signedPayload` JWS를 Apple root PKI로 서명 검증 → `notificationType`(`SUBSCRIBED`|`DID_RENEW`|`DID_CHANGE_RENEWAL_STATUS`|`EXPIRED`|`DID_FAIL_TO_RENEW`|`GRACE_PERIOD_EXPIRED`|`REFUND`|`REVOKE` 등) + 트랜잭션의 `appAccountToken`·`expiresDate` 추출 → 유저 매핑 → `iap_entitlements` 갱신 → 활성/비활성에 따라 `app_metadata.tier` 동기화.
- **인증/보안:** 유저 JWT 없음. 신뢰는 **오직 JWS 서명 검증**으로. 검증 실패 시 400. 서명 검증 없는 본문은 절대 신뢰 금지.
- **Response 200:** `{ "received": true }` (빠르게 200 반환 — Apple은 non-2xx 시 재시도. 처리 실패해도 가능하면 200 + 비동기 로깅하되, 검증 실패만 400).
- **Error:** `400` — JWS 검증 실패. (그 외는 200으로 받고 내부 로깅 — 재시도 폭주 방지)
- **멱등성:** 같은 notification UUID/트랜잭션 재수신 시 동일 결과(upsert). `notificationUUID` 중복 무시.
- **환경:** Apple은 Production/Sandbox용 **별도 웹훅 URL**을 호출. 같은 엔드포인트가 payload의 `environment`로 분기.

#### 3.2-c GET /api/iap/status  *(Track A)*
- **Request:** header `Authorization: Bearer <jwt>`.
- **동작:** 현재 user_id의 `iap_entitlements` 최신 상태 반환(앱 시작/복원 시 재동기화용). 필요 시 `app_metadata.tier` 재설정(웹훅 누락 복구).
- **Response 200:** `{ "tier": "pro"|"normal", "product_id": string|null, "expires_at": ISO8601|null, "active": boolean }`
- **Error:** `401`. 미구매 유저는 200 + `{"tier":"normal","active":false,"product_id":null,"expires_at":null}`.

---

## 4. 구현 설계

### 4.1 신규 백엔드 모듈

- `app/services/apple_iap.py`(신규) — Apple JWS(서명 트랜잭션·ASSN payload) 서명 검증 + 디코드. **라이브러리 결정 필요(§6.x-1):** Apple 공식 `app-store-server-library`(python) 권장 vs 수동 x5c 체인 검증. bundleId·productId·appAccountToken·expiresDate·environment 추출.
- `app/services/supabase_admin.py`(확장) — `set_app_metadata(user_id, patch: dict)` 추가. **read-modify-write 또는 merge**로 `role` 등 기존 키 보존(§6.x-3). `delete_auth_user`와 동일 httpx/service_key 패턴(`supabase_admin.py:32-54`).
- `app/services/iap_service.py`(신규) — verify/webhook/status 공통 로직: 트랜잭션 → entitlement upsert → tier 동기화. `entitlements` 활성 판정(expires_date > now & not revoked).
- `app/routers/iap.py`(신규) — 위 3개 엔드포인트. `main.py`에 `include_router(iap.router)`.
- `app/models/iap.py`(신규) + alembic 마이그레이션 — §4.3.
- `app/core/config.py`(확장) — `APPLE_BUNDLE_ID`, `APPLE_IAP_PRODUCT_ID_PRO_MONTHLY`, (선택) App Store Server API 키(`APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`) — reconciliation용. JWS-only로 시작 가능하면 키 불필요(§6.x-2).

### 4.2 iOS 변경

- `ScatchLM/Services/StoreKitService.swift`(신규) — StoreKit 2: `Product.products(for:)`, `purchase(options: [.appAccountToken(uid)])`, `Transaction.updates` 리스너, `Transaction.currentEntitlements`(복원), `AppStore.sync()`(restore 버튼). 구매·갱신 verify는 `POST /api/iap/verify` 호출 후 `AuthService.refreshSession()`.
- `ScatchLM/Services/AuthService.swift`(확장) — `refreshSession()` 래퍼(supabase-swift `client.auth.refreshSession()`). 구매 검증 후 호출해 tier=pro JWT 즉시 반영.
- `ScatchLM/Views/SettingsSheet.swift`(확장) — "Pro 구독" 섹션: 현재 tier 표시, 구독 버튼(가격은 StoreKit `Product.displayPrice`), 복원 버튼, 관리(앱스토어 구독 관리 링크). 기존 섹션 패턴(`SettingsSheet.swift:49-84`).
- `ScatchLM/Views/PaywallView.swift`(신규, 선택) — quota 429 도달 시 업그레이드 CTA(F-4 429 처리와 연계, 기존 `APIClient` quotaExceeded).
- `ScatchLM/Utilities/Config.swift`(확장) — `proMonthlyProductID = "com.joho54.scatchlm.pro.monthly"` (`Config.swift:23` bundleID 인접).
- `ScatchLM/ScatchLM.entitlements` + `project.yml` — **In-App Purchase capability** 추가(`project.yml:45-48` entitlements에 applesignin 옆).

### 4.3 데이터 모델 (신규 — alembic 마이그레이션 필요)

`iap_entitlements` 테이블:
| 컬럼 | 타입 | 비고 |
|---|---|---|
| `user_id` | text | Supabase uid (FK 없음 — auth는 Supabase 소관) |
| `original_transaction_id` | text | Apple 구독 식별자(PK 후보) |
| `product_id` | text | |
| `status` | text | `active`\|`expired`\|`refunded`\|`revoked` |
| `expires_at` | timestamp | nullable |
| `environment` | text | `Production`\|`Sandbox` |
| `last_notification_type` | text | nullable (감사) |
| `updated_at` | timestamp | |

- 키: `original_transaction_id` unique. 조회: `user_id`. 활성 판정: `status==active && expires_at > now`.
- **마이그레이션 필요**(iOS GRDB는 무관 — 서버 전용).

### 4.4 freemium 무료 tier (config — 코드 아님)

quota는 이미 tier 분기를 강제하므로 코드 변경 없음. **출시 config 결정(상세 산정·근거는 §10):**
- `DAILY_COST_LIMIT_NORMAL_USD` = **$0.15** (≈ complex 7건/일 또는 simple 150건/일). 0(무제한)이면 freemium 의미 없음 — **반드시 양수**.
- `DAILY_COST_LIMIT_PRO_USD` = **$1.00** (≈ complex 50건/일). 가격 산정 기준이 아니라 **abuse 상한**(§10).
- 구체값은 베타 `LLMUsage.cost_usd` 데이터로 보정(§6.x-5). 특히 **pro 평균 사용량이 손익분기(≈10건/일)를 넘는지** 모니터링.

---

## 5. 구현 단계 (Tracks)

### 5.1 의존성 그래프

```
계약 동결(§3) ─── 전 트랙 전제. 완료.
       │
       ├── Track A (BE: IAP 검증·웹훅·entitlement) ── 단일 BE 영역, 파일 공유라 내부 순차
       │     A-1 모델+마이그레이션 ─→ A-2 apple_iap(JWS검증) ─→ A-3 supabase set_app_metadata
       │       ─→ A-4 iap_service+라우터(verify/notifications/status)
       │
       ├── Track B (iOS: StoreKit 구매·복원·UI) ── 계약(§3.2-a/c)으로 독립, 스텁 개발 가능
       │     B-1 StoreKitService ─→ B-2 refreshSession+verify 연동 ─→ B-3 SettingsSheet/Paywall UI
       │
       └── Track C (인프라/ASC) ── 설정, B에 product id 제공(스텁 가능)
             C-1 ASC 구독상품·그룹·가격 · C-2 ASSN v2 웹훅 URL 등록(Prod+Sandbox) ·
             C-3 샌드박스 테스터 · C-4 quota 무료/유료 한도 config(§4.4) · C-5 Caddy 경로(웹훅은 기존 BE 라우트라 추가 불필요, /api/iap/* 노출 확인)
```

### 5.2 트랙 간 의존성

- **계약 동결로 A(BE) ↔ B(iOS) 진짜 병렬.** B는 §3.2-a/c 계약으로 `URLProtocol` 스텁 개발, 실제 검증은 A-4 완료 필요(통합).
- **B 통합 테스트는 C-1(ASC 상품) 필요** — StoreKit `Product.products(for:)`가 실 상품 id를 ASC에서 받아옴. 단위/스텁은 블록 안 됨.
- **A 웹훅 e2e는 C-2(웹훅 URL 등록) 필요.** 검증 로직 자체는 독립.
- **A 내부는 순차** — `iap_service.py`·`supabase_admin.py`·`iap.py`를 공유하므로 한 트랙. verify와 webhook이 같은 검증/tier-set 로직 공유.
- **G-2(prod 배포)** — launch-readiness Track G와 동일하게 BE 변경(A) + 신규 env + `iap_entitlements` 마이그레이션을 함께 배포.

### 5.3 인원별 배분

| 인원 | 추천 배분 |
|---|---|
| 1명 | C-1/C-4(설정) → A → B → C-2(웹훅) → 통합. (가격·상품 먼저 정해야 B의 StoreKit이 돈다) |
| 2명 | **BE:** A + C-2/C-4. **iOS:** B + C-1/C-3(ASC·샌드박스). |
| 3명+ | BE 단일 영역이라 A 분할 효용 낮음. 2명 + 1명은 ASC/QA/문서. |

### Track A — BE: IAP 검증·웹훅·entitlement
**의존:** 없음 (계약 §3.2 동결). **내부 순서:** A-1 → A-2 → A-3 → A-4 (파일 공유 순차).
**작업량:** 큼. 가장 복잡: A-2 Apple JWS 서명 검증(PKI 체인) + A-4 웹훅 라이프사이클→tier 동기화(멱등·환경 분기).

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `app/models/iap.py`(신규), alembic 마이그레이션 | `iap_entitlements` 테이블(§4.3) |
| A-2 | `app/services/apple_iap.py`(신규), `core/config.py` | Apple JWS(트랜잭션·ASSN) 서명 검증·디코드. bundleId/productId/appAccountToken/expiresDate/environment 추출. 라이브러리 결정(§6.x-1) |
| A-3 | `app/services/supabase_admin.py` | `set_app_metadata(user_id, patch)` — merge로 `role` 보존(§6.x-3). 기존 httpx 패턴 재사용 |
| A-4 | `app/services/iap_service.py`(신규), `app/routers/iap.py`(신규), `main.py` | verify/notifications/status 3엔드포인트(§3.2). entitlement upsert → tier 동기화. appAccountToken→user 매핑. 멱등 |

**검증:** 샌드박스 구매 → `/verify` 200(pro) → JWT refresh 후 `/feedback`이 pro 한도. ASSN `EXPIRED` 모의 payload → tier=normal. 위조 JWS → 400.

### Track B — iOS: StoreKit 구매·복원·UI
**의존:** 계약 §3.2-a/c. 통합은 A-4 + C-1.
**내부 순서:** B-1 → B-2 → B-3.
**작업량:** 큼. 가장 복잡: B-1 StoreKit 2 트랜잭션 리스너·복원·appAccountToken 결합 + 검증/refresh 타이밍.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `Services/StoreKitService.swift`(신규), `Config.swift` | `Product.products(for:)`, `purchase(options:[.appAccountToken(uid)])`, `Transaction.updates` 리스너, `currentEntitlements`(복원), `AppStore.sync()` |
| B-2 | `Services/StoreKitService.swift`, `AuthService.swift`, `APIClient.swift` | 구매·갱신 트랜잭션 → `POST /api/iap/verify` → 200/pro면 `refreshSession()`. 앱 시작 시 `GET /api/iap/status` 재동기화 |
| B-3 | `Views/SettingsSheet.swift`, `Views/PaywallView.swift`(신규) | "Pro 구독" 섹션(가격·구독·복원·관리). quota 429(`APIError.quotaExceeded`) → Paywall CTA |

**검증:** 샌드박스 구매 → 즉시 pro 반영(refresh). 앱 재설치 후 복원으로 pro 복귀. 429 시 paywall 노출.

### Track C — 인프라 / App Store Connect
**의존:** C-1 product id → B(스텁 가능). C-2 → A 웹훅 e2e.
**내부 순서:** 대체로 병렬.
**작업량:** 중간. 가장 복잡: C-2 ASSN v2 URL 등록 + 샌드박스/프로덕션 환경 분리 검증.

| ID | 대상 | 내용 |
|---|---|---|
| C-1 | App Store Connect | 자동갱신 구독 그룹 + `com.joho54.scatchlm.pro.monthly` 상품·가격·로컬라이즈·심사 스크린샷 |
| C-2 | ASC + 백엔드 | ASSN v2 웹훅 URL(`https://scatchlm.duckdns.org/api/iap/notifications`) 등록(Production·Sandbox 각각) |
| C-3 | ASC | 샌드박스 테스터 계정, StoreKit Configuration(로컬 테스트용 .storekit) |
| C-4 | `.env.prod` | `DAILY_COST_LIMIT_NORMAL_USD`(양수, COGS 방어), `_PRO_USD`, `APPLE_BUNDLE_ID`, product id, (선택) App Store Server API 키 |
| C-5 | 배포 | A의 BE 변경 + `iap_entitlements` 마이그레이션 함께 배포(launch-readiness G-2와 동일 흐름) |

**검증:** ASC 상품이 StoreKit에 노출, 웹훅이 백엔드에 도달(서명검증 통과), prod `/api/iap/*` 200.

---

## 6. 확인 완료 사항 (코드 검증)

1. **tier는 검증된 JWT에서만** — `auth.py:65-68` `get_tier`가 서명 검증된 `app_metadata.tier`를 읽음(`verify_signature:False` 경로 미사용). → tier flip은 **token refresh 필요**(eventually-consistent).
2. **quota가 이미 tier 분기** — `quota.py` `_limit_for_tier`/`check_daily_quota`가 normal/pro 한도 적용. **freemium은 config만**(코드 변경 없음).
3. **service-role 클라이언트 존재** — `supabase_admin.py:32-54` httpx + `SUPABASE_SERVICE_ROLE_KEY`로 Admin REST. `app_metadata` 설정 메서드만 추가하면 됨(`PUT /auth/v1/admin/users/{id}` 추정 — §6.x-3 확인).
4. **라우터 등록 패턴** — `main.py:12,37-42` `include_router`. iap 라우터 동일 추가.
5. **StoreKit 부재** — iOS `grep StoreKit/Transaction/Product` 0건. 전부 신규.
6. **세션 갱신 가능** — `AuthService`가 supabase-swift `client`(`AuthService.swift:14`) 보유. `refreshSession()` 래퍼만 추가(supabase-swift 2.x 지원 — §6.x-4 시그니처 확인).
7. **entitlements 파일·capability** — `project.yml:45-48` entitlements(`applesignin`) 존재. In-App Purchase capability 추가 지점 확보.
8. **설정 UI 패턴** — `SettingsSheet.swift:49-84` Section 패턴. "Pro 구독" 섹션 추가 위치 명확.
9. **단가** — `feedback_service.py:60-62` Sonnet $3/$15, Haiku $0.25/$1.25. freemium 무료 한도 산정 근거.

### 6.x 미확인 항목

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | Apple JWS 검증 라이브러리(python `app-store-server-library` vs 수동 x5c 체인) | 두 방식 PoC. 공식 라이브러리 우선 평가(유지보수·root cert 갱신) |
| 2 | JWS-only 검증으로 충분한가 vs App Store Server API 키(reconciliation) 필요 | 출시 MVP는 JWS+웹훅으로 시작 가능 여부 검증. 정기 reconcile은 fast-follow |
| 3 | Supabase Admin `app_metadata` 갱신 엔드포인트·**merge vs replace** 동작 | `PUT /auth/v1/admin/users/{id}` body `{"app_metadata":{...}}` 실호출 — `role` 보존되는지(merge) 확인. 미보존이면 read-modify-write |
| 4 | supabase-swift `refreshSession()` 정확한 API·강제 갱신 동작 | supabase-swift 2.x 문서/소스 확인 |
| 5 | 무료/유료 일일 한도 구체 금액(USD) | 베타 `LLMUsage.cost_usd` 분포로 역산. 무료는 COGS 방어선 양수 |
| 6 | `appAccountToken`(UUID) ↔ Supabase user_id(소문자 UUID) 포맷 일치 | `AuthService.syncUserId`(소문자) 사용. StoreKit appAccountToken은 UUID 타입 — 변환 일관성 확인 |
| 7 | ASSN v2 알림 타입별 tier 매핑 표 완성도(GRACE_PERIOD, REVOKE, REFUND 등) | Apple ASSN v2 스키마로 타입→active/inactive 매핑표 작성 |
| 8 | Apple 심사 — paywall/복원 필수 요건, "구매 없이도 핵심 사용 가능" 여부 | freemium라 무료 tier가 사용 가능 → 일반적으로 OK. 복원 버튼·약관·가격 명시 필수 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| JWT tier lag — 만료/환불 후에도 토큰 TTL(~1h)간 pro 유지 | 중 | 허용(짧음). 토큰 TTL 단축 검토. `GET /status`로 앱 시작 시 재동기화 |
| ASSN 웹훅 누락(Apple 재시도에도 영구 실패) | 중 | `iap_entitlements` source of truth + 앱 시작 `/status` 재동기화. fast-follow로 정기 reconcile 잡 |
| 구매 후 verify/refresh 실패 → 결제했는데 normal | 높 | `Transaction.updates` 리스너가 미검증 트랜잭션 재시도(unfinished). verify 성공까지 `finish()` 보류 |
| Apple JWS 검증 오구현(위조 통과) | 높 | 공식 라이브러리 우선(§6.x-1). bundleId·환경·서명 전부 검증. 웹훅은 서명만으로 신뢰 |
| `set_app_metadata`가 `role` 등 기존 키 clobber | 높 | merge 확인(§6.x-3). 불확실하면 read-modify-write 강제 |
| service-role 키 유출 | 높 | `.env.prod`만, 응답·로그 노출 금지(기존 정책) |
| 무료 한도 0/미설정으로 출시 → freemium 붕괴(무제한 무료) | 높 | C-4에서 `DAILY_COST_LIMIT_NORMAL_USD` 양수 강제. 배포 체크리스트 |
| 샌드박스/프로덕션 환경 혼선 | 중 | payload `environment`로 분기. 웹훅 URL Prod/Sandbox 각각 등록(C-2) |
| 환불 abuse(환불 후 토큰 만료까지 사용) | 낮 | TTL 짧음 + REFUND 웹훅 즉시 반영. 손실 미미 |
| 출시 지연(StoreKit 라이프사이클 구현 분량) | 중 | happy-path 먼저, 라이프사이클(갱신/만료/환불 동기화) 철저. 무료 tier는 이미 동작하므로 구독 미완이어도 무료 출시 fallback 가능 |

---

## 8. 출시 게이트 (요약)

**구독 출시 필수:** A-1~A-4(BE 검증·웹훅·entitlement) · B-1~B-3(StoreKit·UI) · C-1(ASC 상품) · C-2(웹훅 URL) · C-4(무료 한도 양수 + env).
**fast-follow 허용:** 정기 reconciliation 잡 · App Store Server API 키 기반 보강 · PaywallView 고도화 · 연간/체험 플랜.
**fallback:** 구독 트랙이 출시를 너무 늦추면, **무료 tier(낮은 quota)만으로 먼저 출시**하고 구독을 fast-follow — freemium 무료 측은 이미 동작(quota config만). 단 "무료→유료 배신감"(§사용자 논의)은 이 fallback의 비용.

---

## 9. 구현 현황 (2026-06-02)

### 완료 (코드)
- **Track A (BE) 전체:**
  - `app/models/iap.py` + alembic `588f1d04cd22_iap_entitlements_table` (적용됨).
  - `app/services/apple_iap.py` — Apple 공식 `app-store-server-library==3.1.2`로 JWS 서명 검증(결정 §6.x-1). root cert는 `app/services/apple_certs/AppleRootCA-G3.cer` 번들. online check off(§6.x-2 MVP). Prod/Sandbox verifier 순차 시도로 환경 분기.
  - `app/services/supabase_admin.py::set_app_metadata` — **read-modify-write merge**로 `role` 보존(§6.x-3 방어적 선택).
  - `app/services/iap_service.py` + `app/routers/iap.py` — verify/notifications/status 3엔드포인트. `main.py` 등록. 멱등 upsert(ON CONFLICT).
  - 테스트: `tests/test_iap.py` 11건 통과(검증 성공/만료/위조 400/계정 불일치 409/status/웹훅 EXPIRED·DID_RENEW). 전체 스위트 93건 통과.
- **Track B (iOS) 전체:**
  - `Services/StoreKitService.swift`(신규) — products/purchase(appAccountToken)/Transaction.updates/currentEntitlements/AppStore.sync. 검증 성공까지 finish 보류(§7).
  - `Services/AuthService.swift::refreshSession()` + `tier` accessor(§6.x-4 supabase-swift 2.x `refreshSession()` 사용).
  - `Services/APIClient.swift` — `iapVerify`/`iapStatus`.
  - `Views/PaywallView.swift`(신규) + `Views/SettingsSheet.swift` "구독" 섹션 + `NoteView` 429→Paywall CTA.
  - `App/ScatchLMApp.swift` — 시작 시 `StoreKitService.shared.start()`. 시뮬레이터 빌드 성공.
- **C-4 config:** `core/config.py`에 `APPLE_BUNDLE_ID`/`APPLE_IAP_PRODUCT_ID_PRO_MONTHLY`/`APPLE_APP_APPLE_ID`. `.env.prod.example`에 IAP 블록 + freemium 양수 한도 NOTE.

### 남은 수동 작업 (Track C — App Store Connect UI / 배포, 코드 외)
- **C-1:** ASC에서 자동갱신 구독 그룹 + `com.joho54.scatchlm.pro.monthly` 상품·가격·로컬라이즈·심사 스크린샷 등록. (IAP capability는 App ID에 활성 — automatic signing이 처리. `.entitlements` 키 불필요.)
- **C-2:** ASSN v2 웹훅 URL `https://scatchlm.duckdns.org/api/iap/notifications`를 ASC에 Production·Sandbox 각각 등록.
- **C-3:** 샌드박스 테스터 계정 + (로컬 테스트용) `.storekit` Configuration.
- **C-5 배포:** `iap_entitlements` 마이그레이션 + 신규 env + 새 의존성(`app-store-server-library` 등 requirements.txt 반영됨)을 함께 배포. `APPLE_APP_APPLE_ID`(프로덕션 웹훅 검증용)는 ASC 앱 생성 후 채울 것.

---

## 10. 가격 정책 (2026-06-02 결정)

### 10.1 단가 (코드 검증 — `feedback_service.py:60-63`)

| 모델 | 용도 | input ($/1M) | output ($/1M) |
|---|---|---|---|
| Sonnet 4.6 | complex 피드백 | 3.0 | 15.0 |
| Haiku 4.5 | simple 피드백·인식·쿼리리라이트 | 0.25 | 1.25 |

**건당 비용(추정, 베타 데이터로 보정 — §6.x-5):**
- complex 피드백(Sonnet, 전형 input ~2.5k / output ~600): **≈ $0.02/건** (가벼움 $0.012 ~ 무거움 $0.026). 인식 Haiku 사전패스 ~$0.0007은 무시.
- simple 피드백(Haiku): ≈ **$0.001/건** (사실상 무시). 비용은 거의 전적으로 complex(Sonnet)가 결정.

quota는 **비용 기준**이므로 `DAILY_COST_LIMIT_*` = 유저당 일일 최대 COGS. 위 건당 비용으로 "한도 ↔ 건수/일"이 환산된다.

### 10.2 가격·수수료 (결정)

| 항목 | 값 |
|---|---|
| Pro 월 구독가 | **₩9,900 / 월** (≈ $7.2, 환율 ~₩1,375/$) |
| Apple 수수료 | **15%** (App Store Small Business Program 가입 — 연 매출 <$1M 신규 앱 해당) |
| **순매출/구독** | ₩8,415 ≈ **$6.1 / 월** |

### 10.3 핵심 원리 — 한도는 가격 기준이 아니라 abuse 상한

워스트케이스(매일 한도 맥스아웃)를 가격으로 커버하는 건 **불가능**(pro $1/일 맥스 = $30/월 COGS ≫ $6.1 순매출). 따라서:
1. **`DAILY_COST_LIMIT_PRO_USD` = abuse 천장**. 폭주/악용을 막되, 정상 유저는 도달하지 않는 선.
2. **가격은 기대 사용량으로 산정.** 손익분기 = 순매출 ÷ 건당비용 = $6.1 ÷ $0.02 = **월 ~305건 = 평균 ~10 complex건/일**.
   - pro 유저 평균이 **하루 10건 이하 → 흑자**, 초과 → 그 유저는 적자(가벼운 유저가 보전).
3. **무료 tier도 실비용 발생** — $0.15/일 맥스 시 $4.6/월 COGS(유저는 $0 지불). 그래서 normal 한도는 반드시 양수 + 보수적.

### 10.4 출시 권장 config (`.env.prod`)

| env | 값 | 환산 | 워스트케이스 월 COGS |
|---|---|---|---|
| `DAILY_COST_LIMIT_NORMAL_USD` | **0.15** | complex ~7건/일 (또는 simple ~150건/일) | $4.6 (무료, 미지불) |
| `DAILY_COST_LIMIT_PRO_USD` | **1.00** | complex ~50건/일 (abuse 천장) | $30 (실현 가능성 낮음) |

- 무료 7건/일: 제품 가치 체감엔 충분, 업그레이드 압력 유지. 무료 맥스아웃 COGS 노출 $4.6/월로 제한.
- pro 50건/일: 정상 학생은 거의 도달 안 함. 50건/일을 **매일** 지속하는 유저만 $30/월 적자 발생 → **모니터링 필수**(평균 사용량이 손익분기 10건/일 넘는지).

### 10.5 모니터링·보정 (§6.x-5 연계)

- 베타/출시 후 `LLMUsage.cost_usd`로 **pro 유저 일일 평균 건수 분포** 추적. 평균이 손익분기(~10건/일)를 넘으면: 가격 인상 / pro 한도 하향 / Haiku 라우팅 확대 중 택.
- 환율·Apple 가격대(가격 티어)는 ASC 등록 시점 환율로 재확인. 건당 비용도 실데이터로 교체.

**도구 결정(2026-06-02):** 구독자 0인 출시 직후엔 BI 도구(Metabase 등)는 **시기상조**. `LLMUsage`는 이미 기록되므로 데이터는 자동 축적 → 필요 시 §10.5.1 SQL을 **psql 직접 실행**(`ssh scatchlm` → `docker exec ... psql`)으로 확인. 손이 많이 가는 시점(구독자 수십+, 자동 알림 필요)에 Metabase를 VM 컨테이너 또는 로컬+SSH터널로 도입. 더 가벼운 대안은 `admin.py`(require_admin)에 `GET /api/admin/metrics` KPI 엔드포인트 1개.

#### 10.5.1 모니터링 SQL (psql / 추후 Metabase 공용)

**전제:**
- **tier 판정은 `iap_entitlements`로** (tier는 DB 아닌 Supabase JWT). DB상 "pro" = 활성 entitlement = `status='active' AND (expires_at IS NULL OR expires_at > now())`. ⚠️ 현재 시점 분류라 과거 pro→만료 유저의 과거 사용분은 free로 잡힘(점별 tier 이력 미보존). 추세 감시엔 충분.
- **KST 달력 일 버킷**: `(created_at + interval '9 hours')::date` (`created_at`은 naive UTC 저장, quota 윈도우가 KST).
- **순매출 상수** `6.10` USD = ₩8,415(₩9,900×0.85) ÷ ~₩1,375. 실제 Apple 정산·환율로 갱신.
- 실패 호출 제외하려면 `WHERE error IS NULL` 추가.

```sql
-- (1) 일별 총 COGS 추세 (KST)
SELECT
  (created_at + interval '9 hours')::date AS kst_day,
  count(*)                                AS calls,
  round(sum(cost_usd)::numeric, 4)        AS cogs_usd,
  round(avg(cost_usd)::numeric, 5)        AS avg_cost_per_call
FROM llm_usage
GROUP BY 1
ORDER BY 1 DESC;

-- (2) 비용 분해 — 모델·task_type (COGS 최적화 타깃: Sonnet 비중 확인)
SELECT
  model, task_type,
  count(*)                                                    AS calls,
  round(sum(cost_usd)::numeric, 4)                            AS cogs_usd,
  round(100.0 * sum(cost_usd) / sum(sum(cost_usd)) OVER (), 1) AS pct_of_cost
FROM llm_usage
WHERE created_at >= now() - interval '30 days'
GROUP BY 1, 2
ORDER BY cogs_usd DESC;

-- (3) tier별 일별 COGS + 활성 유저 수 (free의 미수익 비용 분리)
WITH pro_users AS (
  SELECT DISTINCT user_id FROM iap_entitlements
  WHERE status = 'active' AND (expires_at IS NULL OR expires_at > now())
)
SELECT
  (u.created_at + interval '9 hours')::date                  AS kst_day,
  CASE WHEN p.user_id IS NOT NULL THEN 'pro' ELSE 'free' END AS tier,
  count(*)                                                   AS calls,
  count(DISTINCT u.user_id)                                  AS active_users,
  round(sum(u.cost_usd)::numeric, 4)                         AS cogs_usd
FROM llm_usage u
LEFT JOIN pro_users p ON p.user_id = u.user_id
GROUP BY 1, 2
ORDER BY 1 DESC, 2;

-- (4) ★ 손익분기 감시 — pro 구독자별 30일 마진 (margin_usd < 0 = 적자)
WITH pro_users AS (
  SELECT DISTINCT user_id FROM iap_entitlements
  WHERE status = 'active' AND (expires_at IS NULL OR expires_at > now())
),
usage30 AS (
  SELECT user_id,
         sum(cost_usd)                               AS cogs_30d,
         count(*) FILTER (WHERE task_type='complex') AS complex_calls,
         count(*)                                    AS total_calls
  FROM llm_usage
  WHERE created_at >= now() - interval '30 days'
  GROUP BY user_id
)
SELECT
  pu.user_id,
  coalesce(usr.email, '')                                AS email,
  round(coalesce(u.cogs_30d, 0)::numeric, 3)             AS cogs_30d_usd,
  6.10                                                   AS net_rev_usd,
  round((6.10 - coalesce(u.cogs_30d, 0))::numeric, 3)    AS margin_usd,
  coalesce(u.complex_calls, 0)                           AS complex_30d,
  round(coalesce(u.complex_calls, 0) / 30.0, 1)          AS complex_per_day
FROM pro_users pu
LEFT JOIN usage30 u   ON u.user_id  = pu.user_id
LEFT JOIN users   usr ON usr.id     = pu.user_id
ORDER BY margin_usd ASC;

-- (5) ★ 단일 KPI — pro 단위경제 건전성 (대시보드 상단 숫자)
WITH pro_users AS (
  SELECT DISTINCT user_id FROM iap_entitlements
  WHERE status = 'active' AND (expires_at IS NULL OR expires_at > now())
),
usage30 AS (
  SELECT user_id, sum(cost_usd) AS cogs_30d
  FROM llm_usage
  WHERE created_at >= now() - interval '30 days'
  GROUP BY user_id
)
SELECT
  count(*)                                                 AS pro_subscribers,
  round(avg(coalesce(u.cogs_30d, 0))::numeric, 3)          AS avg_cogs_30d_usd,
  6.10                                                     AS net_rev_per_sub_usd,
  round((6.10 - avg(coalesce(u.cogs_30d, 0)))::numeric, 3) AS avg_margin_usd,
  count(*) FILTER (WHERE coalesce(u.cogs_30d, 0) > 6.10)   AS unprofitable_subs,
  round(100.0 * avg(coalesce(u.cogs_30d, 0)) / 6.10, 1)    AS avg_cogs_pct_of_rev
FROM pro_users pu
LEFT JOIN usage30 u ON u.user_id = pu.user_id;

-- (6) Top 비용 유저 (이상치/abuse 탐지)
SELECT
  u.user_id,
  coalesce(usr.email, '')              AS email,
  count(*)                             AS calls_30d,
  round(sum(u.cost_usd)::numeric, 3)   AS cogs_30d_usd
FROM llm_usage u
LEFT JOIN users usr ON usr.id = u.user_id
WHERE u.created_at >= now() - interval '30 days'
GROUP BY u.user_id, usr.email
ORDER BY cogs_30d_usd DESC
LIMIT 20;
```

### 10.6 Out of scope (이번 결정)
연간 플랜·무료체험(intro offer)·다단계 가격은 §1.3대로 후속. 단일 월 구독 ₩9,900으로 시작.

---

## 11. 단가 차감(COGS 인하) 전략

### 11.1 동기 — 가격이 아니라 원가가 진짜 레버

§10.3에서 손익분기 = **평균 ~10 complex건/일**. 유료 전환한 진성 유저는 이를 넘기기 쉬워 **"팔아도 적자"** 구조가 된다. 가격은 시장(상단)·grandfathering(인상 어려움)에 막혀 여유가 적으므로, 마진의 진짜 레버는 **건당 COGS($0.02) 인하**다. 건당 비용을 절반으로 내리면 손익분기가 10→20건/일로 올라가 대부분의 pro 유저가 흑자권에 든다.

비용 구성(complex 전형, input 2.5k/output 600 기준): **output ≈ 55%**($15/1M), **input ≈ 45%**($3/1M). 둘 다 타깃.

### 11.2 레버 우선순위

| # | 레버 | 적용 지점 | 효과 | 품질 리스크 | 판정 |
|---|---|---|---|---|---|
| L1 | **output max_tokens 캡** | `feedback_service.py` (`FEEDBACK_MAX_TOKENS`) | 긴 응답/워스트케이스 output 비용 상한 | 없음(순수 효율) | ✅ 적용 완료 |
| L2 | **프롬프트 캐싱** | chat `system`에 `cache_control` | input의 캐시 적중분 **0.1×**. chat·동일교재 연속에 강함 | 없음(순수 효율) | ✅ 적용 완료(chat) |
| L3 | **모델 라우팅 강화** | `_select_model` (현 task_type 의존) | Haiku 라우팅분 건당 ~20×↓ — 단 효과는 라우팅 비중에 한정 | **높음** | ⚠️ 보류/폐기(§11.3) |
| L4 | **이미지 토큰 절감** | 업로드 전 해상도/압축 (iOS) | **COGS 절감 거의 0**(Anthropic가 이미 캡). UX(대역폭)만 | **높음** | ⚠️ COGS 목적 폐기(§11.3) |

> **결론:** 품질 무손실 레버(L1·L2)는 **이미 소진**. L3·L4는 제품 핵심(피드백 정확도)을 깎아 돈을 아끼는 트레이드오프라 **권장하지 않음**. 추가 마진 개선은 엔지니어링이 아니라 **비즈니스 레버**(가격·한도·연간 플랜·실사용 모니터링)로(§10·§11.6).

### 11.3 상세

**L1 — output 캡 (가장 쉬움, 즉시).**
현재 `max_tokens=4096`. 피드백 전형 output은 ~600토큰이라 평균엔 영향 없지만, **롱테일/폭주 응답을 상한**한다(4096 output = output만 $0.061). 피드백 용도엔 `1024~1536`이면 충분. chat은 별도 판단. → 한 줄 변경, 회귀 위험 낮음.

**L2 — 프롬프트 캐싱.**
Anthropic `cache_control: {type: "ephemeral"}`를 **안정적 prefix**의 마지막 블록에 부착. 캐시 적중 시 해당 input 토큰 **0.1× 과금**(쓰기 1.25×, TTL 5분).
- **피드백(one-shot)**: 이미지가 매 요청 유니크라 캐시 이득은 **동일 교재 연속 제출**(같은 `textbook_context`+`system`이 5분 내 재사용) 정도로 제한적. 큰 `textbook_context`를 별도 캐시 블록으로 두면 그 구간만 적중.
- **chat(`feedback/chat`, 멀티턴)**: system + RAG 컨텍스트 + 대화 prefix가 턴마다 재사용 → **캐싱 효과 큼**. 우선 적용 대상.
- ⚠️ 모델별 **최소 캐시 길이**(약 1024~2048토큰) 미만이면 적중 안 됨 — system 단독은 작아서(~400토큰) 효과 적을 수 있음. 큰 컨텍스트가 붙는 경로에서 유효.

**L3 — 모델 라우팅 강화. ⚠️ 보류/폐기.**
제품의 본질이 "좋은 AI 피드백"인데 비용 절감 위해 Haiku로 내리는 건 **핵심 기능을 직접 열화**. 트레이드오프가 비대칭이다:
- 절감액은 건당 $0.02인데, **오답 피드백 1건의 평판·이탈 손해가 훨씬 큼.**
- 난이도는 일을 해보기 전엔 모름 → 판정용 Haiku 트리아지 1콜은 비용·지연 추가 + **오분류 시 진짜 복잡한 문제를 Haiku로** 보내는 최악 케이스.
→ "명백히 사소한 요청" 클래스가 데이터로 뚜렷이 보이기 전엔 **건드리지 않는다.**

**L4 — 이미지 토큰 절감. ⚠️ COGS 목적 폐기(절감 주장이 부정확했음).**
Anthropic은 이미지를 **내부 리사이즈** 후 과금한다(장변 ~1568px / ~1.15M 픽셀 초과분 자동 축소, 토큰 ≈ w×h/750 → **이미지당 ~1,600토큰에서 캡**). 즉:
- **큰 이미지를 보내도 캡 이상으로 비용이 안 늘어** → 우리는 이미 캡 근처. 추가 절감 없음.
- 토큰을 실제로 줄이려면 **캡 아래로 더 축소**해야 하는데, 그 구간이 바로 **연한 펜·작은 손글씨 인식이 무너지는 지점** = 핵심 입력 훼손.
→ COGS 레버로는 효과 ≈ 0 + 품질 리스크. 단 "불필요하게 거대한 업로드"의 **대역폭·지연 개선**은 별개 UX 과제로 가능(COGS 아님).

### 11.4 측정 (효과 검증)

- **모델 분포**: `llm_usage.model` 이미 기록 → §10.5.1 #2 쿼리로 Sonnet 비중 추적(L3 효과).
- **캐시 적중**: 현재 `LLMUsage`에 캐시 토큰 컬럼 없음. L2 적용 시 `response.usage.cache_read_input_tokens`/`cache_creation_input_tokens`를 `LLMUsage`에 추가 기록(소규모 모델+마이그레이션)해야 적중률 측정 가능 → L2와 함께 fast-follow.
- 목표: 적용 후 §10.5.1 #1 `avg_cost_per_call`이 유의하게 하락하는지.

### 11.5 출시 게이트

- **출시 전 권장(저위험·고효율):** L1(output 캡). 한 줄, 회귀 위험 낮음.
- **fast-follow:** L2(chat 캐싱 우선) → L3(라우팅) → L4(이미지). 베타 `LLMUsage` 분포로 어느 레버가 큰지 보고 우선순위 확정.
- 단가 인하가 충분하면 §10.2 가격을 ₩6,600 등 **가입 친화 구간으로 내릴 여지**가 생긴다(원가 제약 완화 후 재검토).

### 11.6 적용 현황 (2026-06-02)

- **L1 적용 완료:** `feedback_service.FEEDBACK_MAX_TOKENS=1536`(피드백), chat `max_tokens=2048`(`feedback.py`).
- **L2 적용 완료(chat):** chat `system`을 content block 리스트로 바꿔 `cache_control:{ephemeral}` 부착. 비용은 `estimate_cost_from_usage`로 캐시 토큰(read 0.1×/write 1.25×) 반영 → quota 정합. cache 토큰은 로그에 노출(`cache_read`/`cache_write`).
- **테스트:** `tests/unit/test_cost_estimation.py`(캐시 단가 5건), `test_feedback.py` chat 테스트에 cache_control·max_tokens 회귀 가드 추가. 전체 101건 통과.
- **L3·L4 폐기/보류:** 둘 다 핵심 품질(피드백 정확도)을 깎는 트레이드오프 — L3는 데이터 근거 없이는 보류, L4는 COGS 효과가 사실상 없어(Anthropic 캡) 폐기(§11.3). 품질 무손실 레버는 L1·L2로 소진.
- **남은 fast-follow:** 캐시 적중률 측정용 `LLMUsage` 캐시 토큰 컬럼(§11.4)뿐. 피드백 one-shot 캐싱은 효과 제한적이라 미적용(§11.3).
- **추가 마진은 비즈니스 레버로:** 가격(§10.2)·한도(§10.4)·연간 플랜(§10.6)·실사용 모니터링(§10.5).
