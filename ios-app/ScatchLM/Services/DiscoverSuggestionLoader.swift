import Foundation

/// 서재 기반 "공부 시작점" 제안(Haiku)의 세션 캐시 + single-flight 로더.
///
/// 홈 프롬프트 바와 discover 시트가 같은 결과를 공유하게 한다 — 홈은 자주 그려지므로
/// 매 표시마다 Haiku를 부르면 낭비다. 첫 호출만 네트워크를 타고, 이후엔 캐시를 돌려준다.
/// (response_language 변경은 드물어 캐시 키에 넣지 않는다 — 필요 시 invalidate.)
actor DiscoverSuggestionLoader {
    static let shared = DiscoverSuggestionLoader()

    private var cached: [String]?
    private var inflight: Task<[String], Never>?

    private init() {}

    /// 캐시가 있으면 즉시, 없으면 1회만 네트워크(동시 호출은 같은 Task를 공유). 실패는 빈 배열.
    func load(language: String) async -> [String] {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        let task = Task { () -> [String] in
            let res = try? await APIClient.shared.discoverSuggestions(responseLanguage: language)
            return res?.suggestions ?? []
        }
        inflight = task
        let result = await task.value
        cached = result
        inflight = nil
        return result
    }

    /// 서재가 바뀌었거나(교재 추가/삭제) 언어 변경 시 다음 로드에서 재요청하도록 캐시 비움.
    func invalidate() {
        cached = nil
        inflight = nil
    }
}
