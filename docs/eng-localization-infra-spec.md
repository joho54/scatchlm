# iOS UI 국제화(i18n) 인프라: 한국어 하드코딩 → 로컬라이즈 가능

> **Status:** Draft
> **Date:** 2026-06-02
> **Author:** (auto-generated)
> **연관 문서:** `marketing-plan-v1.md` §1.4 (KR 몰빵 — 영어 능동 마케팅은 트리거까지 미룸), `marketing-en-localization-plan.md`

---

## 0. 결정 요약 (이 스펙이 하는 것 / 안 하는 것)

마케팅 논의(`marketing-plan-v1.md` §1.4)에서 **영어 능동 마케팅은 미루되, 앱 use에는 벽을 치지 않는다**로 합의. 그 제품 측 실행이 이 스펙이다.

- **이 스펙 = 인프라만.** 모든 유저향 문자열이 로컬라이제이션 시스템(String Catalog)을 통과하도록 배선한다. **출시 시점 화면은 그대로 한국어**다(소스 언어 = 한국어).
- **영어 번역 자체는 out of scope.** 인프라가 깔리면, 영어 추가는 "며칠 retrofit"이 아니라 **String Catalog의 English 컬럼을 채우는 몇 시간 작업**이 된다. 트리거(§1.4) 충족 시 별도 작업으로 착수.
- **왜 지금:** retrofit 비용은 하드코딩 문자열이 늘수록 커지는 비대칭. 지금 ~140개일 때 깔아두는 게 가장 싸다. 출시 코호트(한국 학생)는 영향 없음.

---

## 1. Background

### 1.1 현재 상태 (코드 검증됨, §6)
- iOS 앱(`ios-app/`, SwiftUI)은 **유저향 문자열 전면 한국어 하드코딩**.
- 로컬라이제이션 API(`String(localized:)` / `LocalizedStringKey` / `NSLocalizedString`) 사용 **0건**.
- 앱 자체 `Localizable.xcstrings` / `.strings` / `.lproj` **없음** (존재하는 건 전부 SPM 의존성 내부).
- `project.yml`에 `knownRegions` / `developmentLanguage` / `CFBundleLocalizations` 설정 **없음**. `GENERATE_INFOPLIST_FILE: true`라 수동 Info.plist 없음.
- 한글 리터럴 분포: `Views/` 123, `Services/` 13(유저향), `Utilities/` 3. `Models/`·`App/` 0.

### 1.2 Out of Scope
| 항목 | 이유 |
|---|---|
| **실제 영어(또는 기타 언어) 번역** | 인프라만 깐다. 번역은 트리거(§1.4) 충족 시 별도 작업. String Catalog English 컬럼 채우기. |
| **AI 응답 언어 설정** (`Config.responseLanguage`, `Config.swift:52-54`) | 이미 존재하는 별개 기능. UI chrome 언어가 아니라 LLM 출력 언어(`response_language` 파라미터). 손대지 않음. |
| **AI 생성 콘텐츠 / 교재 RAG 출력** | MarkdownUI로 렌더되는 LLM 출력. UI chrome 아님. responseLanguage가 관할. |
| **앱 내 언어 수동 전환 UI** ("설정 > 언어") | iOS는 OS 언어를 따르는 게 표준. 인앱 override 토글은 트리거 단계에서 필요 시 검토(per-app language는 iOS 13+ 시스템 설정으로 가능). |
| **백엔드** | UI 문자열은 클라이언트 전용. 서버 변경 없음. |
| **에러 메시지의 서버측 다국어** | APIClient가 status code → 클라 로컬 문자열로 매핑(`APIClient.swift:328-344`). 서버는 코드만 주면 됨. 클라 매핑 문자열만 로컬라이즈. |

### 1.3 기존 코드 정리 대상
- `SyncService.swift:6` `"dirty push → cursor 이후 pull"` 는 `///` doc 주석 내부 인용구 — **문자열 리터럴 아님, 제외.**
- `appLog(...)` 태그·로그 메시지 등 비유저향 문자열은 로컬라이즈 대상 아님 (감사 시 구분).

---

## 2. 문자열 카테고리 (작업 분류의 기준)

SwiftUI에서 로컬라이즈 처리 방식이 둘로 갈린다. 이게 트랙 분리의 핵심.

| 카테고리 | 설명 | 처리 | 코드 변경 |
|---|---|---|---|
| **(A) 자동 로컬라이즈** | `Text("…")`, `Button("…")`, `.navigationTitle("…")`, `.alert("…", …)`, `Label`, `Picker` 라벨 등 — 인자 타입이 `LocalizedStringKey`인 자리에 **문자열 리터럴** | String Catalog가 빌드 시 **자동 추출**. 코드 변경 대부분 불필요 | 거의 없음 |
| **(B) 명시적 래핑 필요** | `String` 변수/리턴값에 담긴 문자열 — Service 에러 메시지, enum `.label` computed property, 문자열 보간이 섞인 것, `String` 타입으로 선언 후 비-LSK 자리에 전달 | `String(localized: "…")` 또는 보간은 `String(localized: "… \(x) …")` 로 명시 래핑 | 있음 (래핑) |
| **(C) 제외** | 코드 주석, 로그 태그(`appLog`), DB 키, `responseLanguage` raw 값("Korean" 등 서버 전송용) | 손대지 않음 | 없음 |

**(B)로 확인된 대표 사례:**
- `Services/APIClient.swift:328-344` — HTTP status → 한국어 에러 문자열 7종(반환 String).
- `Services/StoreKitService.swift:66,72,91,165` — 구매/구독 에러 4종.
- `Services/AuthService.swift:191` — `"로그인이 필요해요."`
- `Utilities/Config.swift` `MathRenderMode.label` (3종: 자동/수식 보기/수식 안 보기) — computed `String` 반환.
- `Views/` 내 문자열 보간 포함 한글 2건.

**주의:** (A)/(B) 정확한 경계는 각 호출부의 **인자 타입**으로만 확정된다(리터럴이 `LocalizedStringKey`로 받아지는지). 감사 task(A-2/B-*)에서 호출부를 확인해 분류를 확정한다 — 위 카운트는 grep 기반 근사치.

---

## 3. 시스템 도식

```
[빌드 전]
SwiftUI Views ──"한글 리터럴"──> 화면 (하드코딩, 로컬라이즈 우회)
Services ──return "한글"──────> 에러 표시

[이 스펙 적용 후]
Localizable.xcstrings (소스=ko)
        ▲ 빌드 시 자동 추출 (카테고리 A)
        │
SwiftUI Views ──Text("한글"=LocalizedStringKey)──> 화면 (ko 렌더, 누락 시 소스 fallback)
Services ──String(localized:"한글")──> (카테고리 B, 명시 래핑) ──추출──▲

[트리거 후 (이 스펙 밖)]
Localizable.xcstrings 에 English 컬럼 채움 → OS 언어 en이면 영어 렌더
```

핵심: String Catalog는 **번역 누락 시 소스 언어(ko)로 fallback**. 따라서 `en`을 knownRegions에 넣고 번역을 비워둬도 영어 유저는 한국어를 본다(degraded지만 안 깨짐). 인프라 단계의 목표는 "배선"이지 "번역"이 아니다.

---

## 4. 구현 설계

### 4.1 String Catalog 도입
- `ScatchLM/Resources/Localizable.xcstrings` 신규 생성(Xcode String Catalog, JSON 포맷). 소스 언어 = `ko`.
- `project.yml`의 `sources`에 포함되도록 배치(`ScatchLM` 디렉토리 하위면 자동 포함 — 현재 `sources: - ScatchLM`).
- 빌드 시 컴파일러가 `LocalizedStringKey` 사용처를 자동 추출 → 카탈로그에 ko 엔트리 채움.

### 4.2 프로젝트 로컬라이제이션 설정 (`project.yml`)
- `options.developmentLanguage: ko` (소스 언어 명시).
- `knownRegions`에 `ko`, `en`, `Base` 포함되도록 구성.
  - **미확인(§6.x):** XcodeGen이 String Catalog 환경에서 knownRegions를 어떻게 주입하는가 — `options`/타겟 설정/`CFBundleLocalizations` 중 어디로 넣는지 검증 필요. `GENERATE_INFOPLIST_FILE: true`라 `INFOPLIST_KEY_CFBundleLocalizations` 또는 프로젝트 knownRegions 경로를 확인.
- 빌드 후 `.app` 번들에 `ko.lproj`(또는 카탈로그 컴파일 산출물)이 들어가는지 확인.

### 4.3 카테고리 B 명시 래핑
- §2 (B) 목록의 String 반환/변수 문자열을 `String(localized:)`로 감싼다.
- 보간 문자열은 `String(localized: "… \(var) …")` 형태(자동 키 생성) 또는 명시 key + interpolation. 키 충돌·중복은 카탈로그에서 병합.
- Service·Utilities는 View 컨텍스트 밖이라 `LocalizedStringKey` 자동 처리가 안 됨 → **반드시 명시 래핑**.

### 4.4 데이터 모델 / 상태
- 변경 없음. 로컬라이제이션은 표시 계층 전용. GRDB 스키마·UserDefaults·API 페이로드 불변.
- `responseLanguage`(AI 출력 언어)와 **혼선 금지** — UI 언어는 OS 로케일을 따르고, AI 출력 언어는 기존 설정 유지.

---

## 5. 구현 단계 (Tracks)

단일 repo(`ios-app`) · 단일 영역(iOS UI)이라 다인 병렬 효용은 제한적이다. 그래도 **카테고리 B 래핑을 파일 그룹으로 쪼개면** 병렬 가능. 카탈로그/설정(Track A)이 **foundation 블로커**다.

```
        ┌─ Track A: 카탈로그 + 프로젝트 설정 (foundation, 선행)
시작 ───┤
        │   (A 완료 후 ↓ B/C 병렬)
        ├─ Track B: Services/Utilities String(localized:) 래핑
        ├─ Track C: Views 보간/비-LSK 문자열 래핑 + 자동추출 감사
        │
        └─ Track D: 검증 (A·B·C 완료 후) ── 빌드·추출 카운트·한국어 렌더 회귀
```

**트랙 간 의존성:**
- B·C는 **A 완료 후** 시작(카탈로그가 있어야 추출 검증 가능). 단 `String(localized:)` 호출 자체는 카탈로그 없이도 컴파일됨 → A와 약하게만 결합. 엄격히는 "A의 카탈로그 파일 생성(A-1)"만 선행되면 됨.
- B·C는 **서로 다른 파일 그룹**(Services/Utilities vs Views) → 병렬.
- D는 전부 완료 후.

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | A → B → C → D 순차 (작은 작업이라 1명으로 충분) |
| 2명 | 1명 A 먼저 → A 완료 후 둘이 B(Services)·C(Views) 분담 → 함께 D |
| 3명+ | 분할 효용 낮음. 2명 + 1명 검증/QA(D) 전담 권장 |

### Track A: String Catalog + 프로젝트 설정
**의존:** 없음 (foundation)
**내부 순서:** A-1 → A-2 → A-3
**작업량:** 작음. 가장 불확실: A-2(XcodeGen knownRegions 주입 방식, §6.x).

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `ScatchLM/Resources/Localizable.xcstrings`(신규) | 빈 String Catalog 생성(소스 `ko`). sources 포함 확인 |
| A-2 | `ios-app/project.yml` | `options.developmentLanguage: ko`; `knownRegions`(ko/en/Base) 주입 — 방식 검증(§6.x). `xcodegen generate` 재생성 |
| A-3 | (빌드) | 시뮬레이터 빌드 → 카탈로그 자동 추출 동작 확인, `.app`에 로케일 산출물 포함 확인 |

### Track B: Services / Utilities 명시 래핑
**의존:** A-1(카탈로그 파일 존재) 후 권장
**내부 순서:** 파일별 독립, 병렬 가능
**작업량:** 작음. 대상 ~16개 문자열.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `Services/APIClient.swift:328-344` | status→문자열 매핑 7종 `String(localized:)` 래핑 |
| B-2 | `Services/StoreKitService.swift`, `Services/AuthService.swift` | 구매/구독/로그인 에러 5종 래핑 |
| B-3 | `Utilities/Config.swift` `MathRenderMode.label` | enum 라벨 3종 래핑 |

### Track C: Views 래핑 + 자동추출 감사
**의존:** A-1 후 권장
**내부 순서:** C-1(감사) → C-2(래핑)
**작업량:** 중간. 123개 중 대부분 (A)라 코드 변경 적으나, (B)/(C) 분류 감사가 핵심.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `Views/*.swift` (15파일) | 호출부 인자 타입 기준 (A)/(B)/(C) 분류 확정. 자동추출 대상 vs 명시 래핑 대상 목록화 |
| C-2 | `Views/*.swift` | (B) 해당분(보간 2건 + 비-LSK String 전달분) `String(localized:)` 래핑. (A)는 무변경 |

### Track D: 검증
**의존:** A·B·C 완료 후
**작업량:** 작음.

| ID | 파일 | 내용 |
|---|---|---|
| D-1 | (빌드) | 시뮬레이터 빌드(`id=E9FA98C5-…`) + 실기기 빌드(연결 시). CLAUDE.md 빌드 정책 준수 |
| D-2 | 카탈로그 | 추출된 ko 엔트리 수 ≈ 유저향 문자열 수인지 확인(누락 문자열 = 미배선 = 추출 안 됨). 누락분 C-1로 환류 |
| D-3 | 런타임 | 한국어 로케일에서 전 화면 텍스트 회귀(렌더 동일). en 로케일로 강제 실행 시 ko fallback 확인(깨짐 없음) |

---

## 6. 확인 완료 사항 (코드 검증)

- **로컬라이즈 API 미사용:** `String(localized:|LocalizedStringKey|NSLocalizedString` grep 결과 `ios-app/ScatchLM` 전역 0건.
- **카탈로그/로케일 부재:** `ios-app` 하위 앱 소유 `.xcstrings`/`.strings`/`.lproj` 없음(의존성 제외).
- **project.yml:** `knownRegions`/`developmentLanguage`/`CFBundleLocalizations` 키 없음. `GENERATE_INFOPLIST_FILE: true`(`project.yml`), iOS 17 타겟, Swift 5.9, Xcode 16.4.
- **한글 분포:** Views 123 / Services 13(유저향) / Utilities 3 / Models 0 / App 0.
- **카테고리 B 실증:** `APIClient.swift:328-344`(7), `StoreKitService.swift:66,72,91,165`(4 라인), `AuthService.swift:191`(1), `Config.swift` `MathRenderMode.label`(3), Views 보간 2.
- **out-of-scope 분리 근거:** `Config.swift:52-54` `responseLanguage`는 UserDefaults 기반 AI 출력 언어로 `NoteView.swift:803` 등에서 `response_language` 파라미터로 서버 전송 — UI chrome과 무관.
- **제외 문자열:** `SyncService.swift:6`은 `///` doc 주석 내부(리터럴 아님).

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | XcodeGen이 String Catalog와 함께 `knownRegions`를 주입하는 정확한 방식 (`options` vs 타겟 설정 vs `INFOPLIST_KEY_CFBundleLocalizations`) | `xcodegen generate` 후 `.xcodeproj`의 `knownRegions` 확인. XcodeGen 문서 `options.developmentLanguage` 동작 검증 |
| 2 | `GENERATE_INFOPLIST_FILE: true` 환경에서 로케일이 번들에 정상 포함되는지 | A-3 빌드 후 `.app` 번들 내 로케일 산출물 확인 |
| 3 | Views 123개 중 실제 (A)/(B) 비율 (코드 변경 규모 확정) | C-1 감사에서 호출부 인자 타입 전수 확인 |
| 4 | `.alert("문자열", isPresented:)` 의 title이 `LocalizedStringKey`로 자동 처리되는지 (메시지 클로저 내부 `Text`/`Button` 포함) | C-1에서 alert 4곳(`PaywallView`/`NoteView`/`SettingsSheet`/`FeedbackChatSheet`) 시그니처 확인 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 자동추출이 동적 구성 문자열을 놓침 | 일부 문자열이 미배선 → 트리거 후 영어 번역해도 그 문자열만 한국어로 남음 | C-1 전수 감사 + D-2 추출 카운트 대조로 누락 탐지 |
| `knownRegions` 주입 방식 불확실(§6.x-1) | A-2 막힘 | XcodeGen 산출물 검증 우선, 필요 시 `INFOPLIST_KEY_CFBundleLocalizations` fallback |
| 한국어 회귀(래핑 중 문자열 변형) | 출시 코호트(한국)에 직접 영향 | D-3 전 화면 렌더 회귀. 래핑은 표시 문자열 불변이 원칙 |
| 빌드 환경 데드락(Sentry 벤더링, CLAUDE.md `project_sentry_spm_deadlock`) | archive 시 이슈 — 단 이건 archive 한정, 일반 빌드/시뮬레이터 무관 | 검증은 시뮬레이터 빌드로(CLAUDE.md 정책). archive 불필요 |
| 인프라만 깔고 "영어 됨"으로 오인 | 미번역 상태로 영어 마케팅 시 한국어 노출 | §0·§1.2 명시 — 번역은 트리거 시 별도 작업, 본 스펙은 배선만 |

---

## 8. 완료 정의 (Definition of Done)

- [ ] `Localizable.xcstrings`(소스 ko) 존재, 빌드 시 유저향 문자열 자동 추출 동작.
- [ ] `project.yml`에 `developmentLanguage: ko` + `knownRegions(ko/en/Base)` 반영, `.xcodeproj` 재생성.
- [ ] 카테고리 B 문자열(Services/Utilities/Views 보간) 전부 `String(localized:)` 래핑.
- [ ] 시뮬레이터(+실기기 가능 시) 빌드 통과, 한국어 렌더 회귀 없음.
- [ ] 추출 엔트리 수 ≈ 유저향 문자열 수(누락 0 확인), en 로케일에서 ko fallback 정상.
- [ ] **영어 번역은 미포함** — 트리거 시 `marketing-en-localization-plan.md` 능동 공략 항목으로 착수.
