# ScatchLM 위젯 (최근 공부한 내용)

홈/잠금화면에 최근 인출 단서(DMNCue 키워드)를 띄우고, 탭하면 해당 세션 대화 시트로
점프하는 WidgetKit 익스텐션. LLM·백엔드 변경 없이 기존 DMNCue 데이터를 위젯으로 투영한다.

## 구성

| 영역 | 위치 |
|------|------|
| 위젯 익스텐션 | `ScatchLMWidget/RecentStudyWidget.swift` |
| 앱↔위젯 공유 계층 | `Shared/WidgetShared.swift` (두 타깃이 함께 컴파일) |
| 딥링크 라우팅 | `ScatchLM/App/DeepLinkRouter.swift` (+ `ScatchLMApp.onOpenURL`) |
| 데이터 적재 | `DatabaseService.insertDMNCues(…, sessionId:)` / `recentCuesForWidget` / `refreshWidgetCues` |
| 타깃·서명 설정 | `project.yml` (`ScatchLMWidgetExtension` 타깃) |

## 데이터 흐름

1. 피드백/채팅 응답의 keywords가 `DMNCue`로 적재될 때 `sessionId`를 함께 링크한다.
   (피드백 경로는 `appendFeedbackCard`가 세션 id를 반환 → 그 자리에서 링크. 가이드챗은
   세션이 없어 `nil` → 노트 폴백.)
2. 적재 직후(및 앱 기동 시) `refreshWidgetCues()`가 사용자 scope 최신 단서 N개를 App Group
   공유 저장소(`UserDefaults(suiteName:)`)에 스냅샷으로 쓰고 `WidgetCenter.reloadAllTimelines()`.
3. 위젯은 그 스냅샷만 읽는다(별도 프로세스라 `scatchlm.db` 직접 접근 불가).
4. 단서 탭 → `scatchlm://session/<sessionId>?note=<noteId>` 딥링크 → 앱이 콜드런치/포어그라운드 →
   `DeepLinkRouter`가 intent stash → `WidgetSessionLoader`가 DB 준비될 때까지 폴링 후
   `SessionChatSheet`를 `onPin=nil`로 표시(노트/캔버스 없이, 읽기·대화 전용).

## 코드 서명 / 프로비저닝 (실기기 빌드 시 필수)

위젯은 **별도 번들 + App Group 공유**라 새 entitlement·번들 id 등록이 필요하다.
시뮬레이터 빌드는 프로비저닝 없이 통과하지만, **실기기/TestFlight는 아래가 충족돼야 한다.**

### 등록 대상

| 항목 | 값 |
|------|------|
| 앱 번들 id | `com.joho54.scatchlm` |
| 위젯 번들 id | `com.joho54.scatchlm.widget` |
| App Group | `group.com.joho54.scatchlm` |
| Team | `Z5U7D89KP7` |

App Group ID는 코드 4곳에 하드코딩돼 있고 **모두 일치해야** 공유 컨테이너가 열린다:
`Shared/WidgetShared.swift`(`appGroupID`), 앱 entitlements(`project.yml` ScatchLM 타깃),
위젯 entitlements(`ScatchLMWidget/ScatchLMWidget.entitlements` + `project.yml` 위젯 타깃).

### 자동 서명 경로 (기본)

`CODE_SIGN_STYLE = Automatic` + `-allowProvisioningUpdates`로 빌드하면 Xcode가
위젯 App ID와 App Group을 자동 등록 시도한다. 대개 이걸로 충분하다:

```bash
cd ios-app
xcodegen generate
xcodebuild -project ScatchLM.xcodeproj -scheme ScatchLM \
  -destination 'id=<DEVICE_UDID>' -allowProvisioningUpdates build
```

### 자동 등록이 실패할 때 (수동 폴백)

App Group은 자동 서명이 못 만드는 경우가 있다. 그러면
[Apple Developer 포털](https://developer.apple.com/account/resources/identifiers/list/applicationGroup)에서 수동으로:

1. **Identifiers → App Groups**에 `group.com.joho54.scatchlm` 생성.
2. **Identifiers → App IDs**에서 앱(`com.joho54.scatchlm`)과 위젯(`com.joho54.scatchlm.widget`)
   각각의 **App Groups** capability를 켜고 위 그룹에 체크.
3. (위젯 App ID가 없으면 먼저 생성 — 자동 서명이 첫 빌드에서 만들어 주기도 한다.)
4. Xcode에서 자동 프로비저닝 프로파일 재발급(Clean build) 후 재빌드.

### 흔한 증상 / 진단

- **빌드 에러 `Provisioning profile doesn't include the application-groups entitlement`**
  → 위 수동 등록 후 프로파일 재발급.
- **위젯이 항상 "아직 공부 기록이 없어요"** (앱엔 단서가 있는데)
  → App Group 컨테이너 공유 실패 신호. `UserDefaults(suiteName:)`가 nil 반환 중일 수 있다.
  App Group ID가 4곳 모두 일치하는지, 두 타깃 entitlements에 모두 들어갔는지 확인.
- **버전 불일치 에러** → 위젯 `MARKETING_VERSION`을 앱과 동일하게 유지(현재 둘 다 `project.yml`에서
  관리, CFBundleVersion은 양 타깃 postBuildScript가 git 커밋 수로 맞춘다).

## 검증 체크리스트 (실기기)

시뮬레이터 통과 ≠ 동작 확인. 실기기에서 직접 확인할 것:

- [ ] 위젯 추가 시 최근 단서가 표시되는가 (App Group 공유 동작)
- [ ] 피드백/채팅 후 위젯이 갱신되는가 (`reloadAllTimelines`)
- [ ] 단서 탭 → 앱 콜드런치 → 해당 세션 시트가 열리는가 (`WidgetSessionLoader` 폴링)
- [ ] 레거시/세션 없는 단서 탭 시 크래시 없이 앱만 열리는가 (노트 폴백)
