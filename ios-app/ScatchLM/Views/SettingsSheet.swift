import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var responseLanguage = Config.responseLanguage
    @State private var mathRenderMode = Config.mathRenderMode

    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var alertMessage: String?

    @State private var store = StoreKitService.shared
    @State private var showPaywall = false
    @State private var restoring = false

    #if DEBUG
    @State private var showDebugCanvas = false
    #endif

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let b = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("피드백 언어") {
                    TextField("예: 한국어, English, 日本語", text: $responseLanguage)
                        .onChange(of: responseLanguage) { _, newValue in
                            Config.responseLanguage = newValue
                        }

                    Text("AI 피드백이 이 언어로 작성됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("수식 렌더링") {
                    Picker("수식 렌더링", selection: $mathRenderMode) {
                        ForEach(Config.MathRenderMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mathRenderMode) { _, newValue in
                        Config.mathRenderMode = newValue
                    }

                    Text("자동: 수식이 있으면 KaTeX로 렌더. 수식 안 보기는 가볍게 텍스트만 표시합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // v1 무료 출시 — 구독 UI 숨김(Config.subscriptionEnabled). ASC 상품 등록 후 노출.
                if Config.subscriptionEnabled {
                Section("구독") {
                    HStack {
                        Text("현재 플랜")
                        Spacer()
                        Text(store.isPro ? "Pro" : "무료")
                            .foregroundStyle(store.isPro ? Color.accentColor : .secondary)
                            .fontWeight(store.isPro ? .semibold : .regular)
                    }

                    if !store.isPro {
                        Button {
                            showPaywall = true
                        } label: {
                            Label("Pro 구독하기", systemImage: "sparkles")
                        }
                    } else {
                        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                            Label("구독 관리", systemImage: "creditcard")
                        }
                    }

                    Button {
                        Task { await restorePurchases() }
                    } label: {
                        if restoring {
                            HStack { ProgressView(); Text("복원 중…") }
                        } else {
                            Text("구매 복원")
                        }
                    }
                    .disabled(restoring)
                }
                }

                Section("도움말") {
                    Button {
                        // 온보딩 게이팅 플래그를 내린다 → 설정 닫고 홈으로 가면 온보딩이 다시 뜬다.
                        UserDefaults.standard.set(false, forKey: "onboardingCompleted")
                        dismiss()
                    } label: {
                        Label("온보딩 다시 보기", systemImage: "sparkles")
                    }
                }

                Section("약관 및 정책") {
                    Link(destination: URL(string: Config.privacyPolicyURL)!) {
                        Label("개인정보 처리방침", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: Config.termsOfServiceURL)!) {
                        Label("이용약관", systemImage: "doc.text")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            try? await AuthService.shared.signOut()
                            dismiss()
                        }
                    } label: {
                        Text("로그아웃")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        if deleting {
                            HStack { ProgressView(); Text("삭제 중…") }
                        } else {
                            Text("계정 삭제")
                        }
                    }
                    .disabled(deleting)
                } footer: {
                    Text("계정과 모든 데이터(노트·피드백·교재)가 영구히 삭제됩니다. 되돌릴 수 없어요.")
                }

                Section {
                    HStack {
                        Text("버전")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                }

                #if DEBUG
                Section("디버그") {
                    Button("캔버스 떨림 소거법 하니스") { showDebugCanvas = true }
                }
                #endif
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .confirmationDialog(
                "계정을 삭제할까요?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("계정 삭제", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("계정과 모든 데이터가 영구히 삭제됩니다. 이 작업은 되돌릴 수 없어요.")
            }
            .alert("알림", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            #if DEBUG
            .fullScreenCover(isPresented: $showDebugCanvas) {
                DebugCanvasView()
            }
            #endif
            .task { await store.refreshFromServer() }
        }
    }

    private func restorePurchases() async {
        restoring = true
        defer { restoring = false }
        let ok = await store.restore()
        alertMessage = ok ? String(localized: "구독이 복원되었어요.") : (store.lastError ?? String(localized: "복원할 구독을 찾지 못했어요."))
    }

    private func deleteAccount() async {
        deleting = true
        defer { deleting = false }
        do {
            let result = try await AuthService.shared.deleteAccount()
            if case .dataDeletedAuthRemains = result {
                appLog("auth", "account deletion: data deleted, auth removal deferred")
            }
            dismiss()
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.")
        }
    }
}
