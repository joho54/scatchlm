import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}

@main
struct ScatchLMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var auth = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase

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
                    NavigationStack {
                        HomeView()
                    }
                } else {
                    LoginView()
                }
            }
            .task {
                await auth.initialize()
                // 구독 라이프사이클 리스너 시작 + 서버 상태 동기화(§B-2). 로그인 후 호출해 status 동기화.
                // v1 무료 출시에선 비활성(Config.subscriptionEnabled=false). ASC 구독 상품 등록 후 켜짐.
                if Config.subscriptionEnabled { StoreKitService.shared.start() }
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
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
