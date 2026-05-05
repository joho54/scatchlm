# ScatchLM Mobile

React Native (Expo SDK 54) iPad 앱. Apple Pencil 기반 외국어 학습 보조.

## 사전 조건

- Node.js, Xcode 설치
- Xcode → Preferences → Accounts → Apple ID 등록
- iPad: 설정 → 일반 → VPN 및 기기 관리 → 개발자 앱 신뢰

## 셋업

```bash
cd mobile
npm install
```

## iPad 빌드 (최초 또는 네이티브 코드 변경 시)

```bash
npx expo run:ios --device <DEVICE_ID> --port 8082
```

- Xcode에서 ScatchLM 타겟 → Signing & Capabilities → Team 설정 필요
- 디바이스 ID 확인: `xcrun devicectl list devices`
- 빌드 시 `scripts/inject-packager-host.sh`가 맥의 현재 IP를 앱에 주입
- Xcode Build Phases에 해당 스크립트가 Run Script로 등록되어 있어야 함

## 개발 서버 (JS/TS 코드만 변경 시)

```bash
npm run metro
```

아이패드에서 앱을 열면 Metro에서 JS 번들을 다운로드하여 실행. Hot Reload 지원.

- 맥과 아이패드가 같은 Wi-Fi에 있어야 함
- 포트: 8082 (8081은 Docker가 점유)
- 로그: `logs/metro.log` (디바이스 console.log 포함)

## Metro 연결 구조

```
[맥] Metro (포트 8082)  ←── JS 번들 요청 ──  [아이패드 앱]
```

앱이 Metro를 찾는 IP는 빌드 시 `AppDelegate.swift`에 주입됨.
IP가 바뀌면 (네트워크 변경 등) 재빌드 필요.

## 주의 사항

- Expo Go 사용 불가 (네이티브 모듈 의존 → dev client 필수)
- 네이티브 의존성 추가 시 재빌드 필수
- `console.log` 출력은 Metro 터미널 + `logs/metro.log`에서 확인
