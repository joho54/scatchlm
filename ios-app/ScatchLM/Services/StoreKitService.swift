import Foundation
import StoreKit

/// StoreKit 2 구독 구매·복원·라이프사이클 (Track B-1/B-2).
///
/// 흐름(§2): `purchase(.appAccountToken(uid))` → 서명 트랜잭션(JWS) → `POST /api/iap/verify`
/// → 200/pro면 `AuthService.refreshSession()`로 tier=pro JWT 즉시 수령 → 검증 성공 후 `finish()`.
///
/// 신뢰 경계: 클라이언트는 entitlement를 자체 판정하지 않는다. 항상 백엔드 `/verify`·`/status`가
/// source of truth. `Transaction.updates` 리스너가 갱신·미검증 트랜잭션을 재처리한다(§7 Risk).
@Observable
@MainActor
final class StoreKitService {
    static let shared = StoreKitService()

    /// 로드된 구독 상품(보통 Pro 월간 1개).
    private(set) var products: [Product] = []
    /// 마지막으로 백엔드가 확인한 pro 여부(UI 표시용 캐시. 권위는 JWT tier / 서버).
    private(set) var isPro: Bool = false
    private(set) var purchasing: Bool = false
    private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    /// 앱 시작 시 1회 호출: 상품 로드 + 미검증 트랜잭션 리스너 시작 + 서버 상태 동기화.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            // 갱신/외부 구매/지연 검증 트랜잭션 — 앱 실행 중 언제든 도착할 수 있음.
            for await result in Transaction.updates {
                await self?.process(result, finishOnSuccess: true)
            }
        }
        Task { await loadProducts() }
        Task { await refreshFromServer() }
    }

    // MARK: - Products

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: [Config.proMonthlyProductID])
            products = loaded
            appLog("iap", "products loaded", ["count": "\(loaded.count)"])
        } catch {
            lastError = error.localizedDescription
            appLogError("iap", "product load failed", ["error": "\(error)"])
        }
    }

    var proProduct: Product? { products.first { $0.id == Config.proMonthlyProductID } }

    /// StoreKit가 제공하는 현지화 가격 문자열(예: "₩4,400"). 미로드면 nil.
    var proDisplayPrice: String? { proProduct?.displayPrice }

    // MARK: - Purchase

    /// Pro 구독 구매. 성공·검증·refresh까지 완료되면 true.
    @discardableResult
    func purchasePro() async -> Bool {
        guard let product = proProduct else {
            await loadProducts()
            guard proProduct != nil else {
                lastError = String(localized: "상품을 불러오지 못했어요. 잠시 후 다시 시도해 주세요.")
                return false
            }
            return await purchasePro()
        }
        guard let uidString = AuthService.shared.syncUserId, let uid = UUID(uuidString: uidString) else {
            lastError = String(localized: "로그인이 필요해요.")
            return false
        }

        purchasing = true
        lastError = nil
        defer { purchasing = false }

        do {
            let result = try await product.purchase(options: [.appAccountToken(uid)])
            switch result {
            case .success(let verification):
                return await process(verification, finishOnSuccess: true)
            case .userCancelled:
                appLog("iap", "purchase cancelled")
                return false
            case .pending:
                // Ask-to-Buy 등 — 추후 Transaction.updates로 도착.
                appLog("iap", "purchase pending")
                lastError = String(localized: "구매 승인 대기 중이에요. 승인되면 자동으로 적용돼요.")
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            appLogError("iap", "purchase failed", ["error": "\(error)"])
            return false
        }
    }

    // MARK: - Restore

    /// 복원: App Store와 동기화 후 현재 entitlement를 백엔드로 재검증.
    @discardableResult
    func restore() async -> Bool {
        do {
            try await AppStore.sync()
        } catch {
            appLogError("iap", "AppStore.sync failed", ["error": "\(error)"])
        }
        var restored = false
        for await result in Transaction.currentEntitlements {
            if await process(result, finishOnSuccess: false) { restored = true }
        }
        await refreshFromServer()
        appLog("iap", "restore done", ["restored": "\(restored)"])
        return restored
    }

    // MARK: - Server sync

    /// 앱 시작/복원 시 서버 entitlement 상태로 isPro 캐시 동기화(웹훅 누락 복구 포함).
    func refreshFromServer() async {
        guard AuthService.shared.isAuthenticated else { return }
        do {
            let status = try await APIClient.shared.iapStatus()
            isPro = status.isPro
            appLog("iap", "status synced", ["tier": status.tier, "active": "\(status.active ?? false)"])
        } catch {
            appLogError("iap", "status sync failed", ["error": "\(error)"])
        }
    }

    // MARK: - Verification core

    /// 서명 트랜잭션을 백엔드로 검증한다. 성공(pro)이면 refreshSession + finish.
    /// 검증 성공까지 `finish()`를 보류해 결제-검증 race에서 트랜잭션이 유실되지 않게 한다(§7 Risk).
    @discardableResult
    private func process(_ result: VerificationResult<Transaction>, finishOnSuccess: Bool) async -> Bool {
        // 로컬 서명 검증 결과와 무관하게 JWS 원문을 서버로 보낸다(권위는 서버). 단 unverified는 로깅.
        if case .unverified(_, let error) = result {
            appLogError("iap", "transaction unverified locally", ["error": "\(error)"])
        }
        let transaction = unsafeTransaction(result)
        let jws = result.jwsRepresentation

        do {
            let entitlement = try await APIClient.shared.iapVerify(signedTransaction: jws)
            if entitlement.isPro {
                // tier=pro JWT를 즉시 받기 위해 강제 세션 갱신.
                try? await AuthService.shared.refreshSession()
                isPro = true
            } else {
                isPro = false
            }
            if finishOnSuccess {
                await transaction?.finish()
            }
            appLog("iap", "verify ok", ["tier": entitlement.tier])
            return entitlement.isPro
        } catch {
            // 검증 실패 → finish하지 않음. 리스너/다음 시작에서 재시도됨.
            lastError = (error as? LocalizedError)?.errorDescription ?? String(localized: "구독 검증에 실패했어요.")
            appLogError("iap", "verify failed (will retry)", ["error": "\(error)"])
            return false
        }
    }

    /// VerificationResult에서 Transaction을 꺼낸다(검증 여부 무관 — finish 호출용).
    private func unsafeTransaction(_ result: VerificationResult<Transaction>) -> Transaction? {
        switch result {
        case .verified(let t): return t
        case .unverified(let t, _): return t
        }
    }
}
