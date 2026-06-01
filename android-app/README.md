# ScatchLM Android

iOS(`ios-app/`) 네이티브 앱의 Android 포트. Kotlin + Jetpack Compose.
설계/트랙 분배는 `docs/android-port-spec.md` 참조.

## 요구사항
- Android Studio (또는 cmdline-tools) + Android SDK **android-35**, build-tools **35.0.0**
- JDK 17+ (Android Studio 번들 JBR 사용 가능)
- `local.properties` 에 `sdk.dir=<SDK 경로>` (이미 생성됨)

## 빌드
```bash
cd android-app
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"   # 또는 시스템 JDK17
./gradlew :app:assembleDebug
# 산출물: app/build/outputs/apk/debug/app-debug.apk
```

## 실행 (에뮬레이터/실기기)
```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
- 에뮬레이터에서 개발 백엔드 접근: `BuildConfig.API_BASE_URL` 이 `http://10.0.2.2:18000/api`
  (10.0.2.2 = 에뮬레이터 → 호스트 루프백). 실기기는 앱 내 override 또는 LAN IP 필요.
- 백엔드는 `backend/`에서 `make serve` (포트 18000).

## 구조 (iOS 대응)
```
app/src/main/java/com/joho54/scatchlm/
├── Config.kt              # iOS Config.swift
├── ScatchLMApp.kt         # Application + 수동 DI(서비스 로케이터)
├── MainActivity.kt
├── ui/
│   ├── Navigation.kt      # NavHost (login/home/note/pdf)
│   ├── theme/
│   ├── login/             # LoginScreen          ← LoginView
│   ├── home/              # HomeScreen, Create/EditNoteSheet ← HomeView 등
│   ├── note/              # NoteScreen           ← NoteView (핵심)
│   ├── pdf/               # PdfViewerScreen, PdfView, PdfDocumentSource ← PdfViewerView
│   ├── draw/              # InkCanvas, DrawingController, InkRender ← PencilKit
│   ├── feedback/          # FeedbackChatSheet, RatingSheet
│   └── settings/          # SettingsSheet
└── data/
    ├── auth/              # AuthRepository (supabase-kt) ← AuthService
    ├── api/              # ApiClient, ApiService, dto/  ← APIClient
    ├── db/               # Room entities/DAOs/AppDatabase ← GRDB DatabaseService
    ├── log/              # LogService
    └── repo/             # Note/Feedback/Pdf Repository
```

## 기술 매핑 (스펙 §4.1)
| iOS | Android |
|---|---|
| PencilKit | Compose Canvas + 스타일러스 직접 처리 (스펙 §7 폴백; Jetpack Ink 추후 교체) |
| PDFKit | 빌트인 `android.graphics.pdf.PdfRenderer` |
| GRDB | Room |
| supabase-swift | Supabase GoTrue REST 직접 호출 (OkHttp) — supabase-kt(KMP) 대신 경량 REST |
| URLSession | Retrofit + OkHttp |
| MarkdownUI | compose-markdown |
| UserDefaults | SharedPreferences (Config) |

## 알려진 제약 / TODO
- **드로잉 엔진**: 현재 커스텀 Canvas 엔진(스펙 §7 폴백). 압력/틸트/저지연은 미구현 →
  Jetpack Ink(androidx.ink) 안정화 시 `ui/draw/InkCanvas` 내부 교체 (스펙 §6.x-1).
- **드로잉 직렬화 포맷은 iOS와 비호환** (로컬 전용, 의도된 제약).
- 노트/드로잉은 **로컬 캐시만** — 서버 동기화 없음 (iOS와 동일, `docs/notes-sync-todo.md`).
- 피드백 카드 좌표 정합(px↔dp)은 실기기에서 추가 튜닝 필요 (스펙 §6.x-5).
- 컴파일만 검증됨. 런타임(인증 E2E, 피드백 루프) 실기기/에뮬레이터 검증은 미수행.
- 의존성 버전은 빌드로 해석 검증됨 (Compose BOM 2024.12.01, AGP 8.7.3, Kotlin 2.1.0,
  supabase-kt 3.0.3, Room 2.6.1 등 `gradle/libs.versions.toml`).
```
