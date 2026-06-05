import SwiftUI
import StoreKit

/// Pro 구독 업그레이드 화면 (Track B-3).
/// quota 429(`APIError.quotaExceeded`) 도달 시 또는 설정에서 진입. 구매·복원·약관을 한 곳에 모은다.
/// (Apple 심사 요건: 가격 명시 · 복원 버튼 · 약관 링크 — §6.x-8)
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = StoreKitService.shared
    @State private var working = false
    @State private var alertMessage: String?

    /// 진입 사유 문구(예: quota 초과 안내). nil이면 일반 업그레이드.
    var reason: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)

                    Text("ScatchLM Pro")
                        .font(.largeTitle.bold())

                    if let reason {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        benefit(String(localized: "넉넉한 일일 AI 피드백 한도"))
                        benefit(String(localized: "손글씨 인식 · 교재 기반 RAG 채팅"))
                        benefit(String(localized: "스캔본(이미지) PDF 교재 페이지 제한 없이 인식"))
                        benefit(String(localized: "월 자동 갱신 · 언제든 해지"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                    subscribeButton

                    Button("구매 복원") {
                        Task { await restore() }
                    }
                    .disabled(working)

                    Text("구독은 월 단위로 자동 갱신되며, 현재 기간 종료 24시간 이전에 해지하지 않으면 갱신됩니다. 구매 후 Apple ID 설정에서 관리·해지할 수 있어요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 16) {
                        Link("개인정보 처리방침", destination: URL(string: Config.privacyPolicyURL)!)
                        Link("이용약관", destination: URL(string: Config.termsOfServiceURL)!)
                    }
                    .font(.caption)
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task { if store.products.isEmpty { await store.loadProducts() } }
            .alert("알림", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var subscribeButton: some View {
        Button {
            Task { await subscribe() }
        } label: {
            HStack {
                if working {
                    ProgressView().tint(.white)
                } else {
                    Text(buttonTitle)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(working || store.proProduct == nil)
    }

    private var buttonTitle: String {
        if let price = store.proDisplayPrice {
            return String(localized: "\(price) / 월 구독하기")
        }
        return String(localized: "구독하기")
    }

    private func benefit(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text(text)
        }
    }

    private func subscribe() async {
        working = true
        defer { working = false }
        let ok = await store.purchasePro()
        if ok {
            dismiss()
        } else if let err = store.lastError {
            alertMessage = err
        }
    }

    private func restore() async {
        working = true
        defer { working = false }
        let ok = await store.restore()
        if ok {
            alertMessage = String(localized: "구독이 복원되었어요.")
            dismiss()
        } else {
            alertMessage = store.lastError ?? String(localized: "복원할 구독을 찾지 못했어요.")
        }
    }
}
