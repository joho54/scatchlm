import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // iPhone 컴패니언(iphone-companion-app-spec §4.1): iPhone은 portrait 전용.
        // iPad는 기존 동작 유지(가로 분할 영향 없음 — 전역 .portrait 락은 INFOPLIST 4방향과
        // 공존하던 기존 거동 그대로). idiom 분기로 iPhone 동작만 명시적으로 확정한다.
        if Platform.isPhone {
            return .portrait
        }
        return .portrait
    }
}

@main
struct ScatchLMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var auth = AuthService.shared
    @State private var router = DeepLinkRouter()
    @Environment(\.scenePhase) private var scenePhase
    /// 첫 실행 게이팅(onboarding-guided-first-success-spec §4.1). 완료/건너뛰기 시 true.
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    init() {
        // 가장 먼저 Sentry 시작 — 이후 발생하는 크래시/예외를 포착(spec §4.2·B-2).
        Observability.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isLoading {
                    ProgressView("불러오는 중…")
                } else if auth.isAuthenticated {
                    authenticatedRoot
                        // 위젯 딥링크로 들어온 세션을 루트에서 표시(노트 진입 없이). 인증된 서브트리에만
                        // 붙어, 로그인 전 들어온 intent는 로그인 완료 후 이 시트가 나타날 때 표시된다.
                        .sheet(item: $router.pending) { pending in
                            WidgetSessionLoader(pending: pending) { router.pending = nil }
                        }
                } else {
                    LoginView()
                }
            }
            .onOpenURL { router.handle($0) }
            .task {
                // 빌드 마커 — 기기에 어떤 빌드가 깔렸는지 app_logs로 확정(진동 픽스 검증용).
                // 픽스/계측 바꿀 때마다 build 값을 올려 재현 로그가 어느 빌드인지 구분한다.
                appLog("boot", "build marker", ["build": "revert-bake-1"])
                track(.appOpen, .ok)   // 세션 분모(퍼널 D1/D3) — session_id 기준
                await auth.initialize()
                // 위젯 공유 스냅샷을 현재 계정 기준으로 갱신(로그인/계정전환 반영). 단서 적재 시에도
                // 갱신되지만, 앱 기동 시 한 번 맞춰 둬야 위젯이 비거나 이전 계정 단서를 들고 있지 않다.
                DatabaseService.shared.refreshWidgetCues()
                // 구독 라이프사이클 리스너 시작 + 서버 상태 동기화(§B-2). 로그인 후 호출해 status 동기화.
                // v1 무료 출시에선 비활성(Config.subscriptionEnabled=false). ASC 구독 상품 등록 후 켜짐.
                if Config.subscriptionEnabled { StoreKitService.shared.start() }
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
        }
    }

    /// 인증된 루트 — iPhone 컴패니언(읽기 전용) vs iPad 편집 경로(iphone-companion-app-spec §4.1·B-2).
    @ViewBuilder
    private var authenticatedRoot: some View {
        if Platform.isPhone {
            // iPhone 컴패니언은 읽기 전용 — 온보딩(필기→피드백)은 iPad에서만.
            PhoneHomeView()
        } else {
            HomeView()
                .fullScreenCover(isPresented: Binding(
                    get: { !onboardingCompleted },
                    set: { if !$0 { onboardingCompleted = true } }
                )) {
                    OnboardingView(completed: Binding(
                        get: { onboardingCompleted },
                        set: { onboardingCompleted = $0 }
                    ))
                }
        }
    }

    /// 동기화 트리거 결선 (§4.2 / D-2·D-3).
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            appLog("lifecycle", "scenePhase active")
            // foreground 진입: dirty push → pull (송신 시작점)
            SyncService.shared.requestSync()
        case .background, .inactive:
            appLog("lifecycle", "scenePhase background/inactive")
            // 로그 버퍼도 즉시 flush (유실 방지, O6)
            LogService.shared.flush()
            // background/종료 직전: 디바운스 취소 + 즉시 dirty flush (송신 보장)
            flushOnBackground()
        @unknown default:
            break
        }
    }

    /// background 전환 시 짧은 실행 유예를 확보해 마지막 편집을 flush (§7 background flush).
    private func flushOnBackground() {
        let app = UIApplication.shared
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = app.beginBackgroundTask(withName: "sync-flush") {
            if bgTask != .invalid { app.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        Task {
            await SyncService.shared.flush()
            if bgTask != .invalid { app.endBackgroundTask(bgTask); bgTask = .invalid }
        }
    }
}
