import Foundation

/// DMN 휴식-시간 인출 단서(keywords)를 답변 생성과 분리해 비동기로 모은다.
///
/// 과거엔 답변 콜(피드백/채팅)이 같은 응답에 keyword를 함께 실어 보냈는데, 본문이 keyword 필드로
/// 오배치되거나 잘리는 자잘한 사고가 반복됐다. 이제 답변은 순수하게 받고, 답변 수신 후 이 경로로만
/// 단서를 추출한다(POST /api/feedback/cues, 저비용 Haiku).
///
/// 비용을 줄이려 매 교환마다 추출하지 않고 **드문드문** 한다: 노트별 교환 N회마다 1회.
/// 단, 노트에 단서가 하나도 없으면 무조건 추출해 첫 단서를 보장한다(빈 노트 방어).
enum CueService {
    /// 노트별 교환 몇 회마다 단서를 추출할지. 1이면 매번.
    static let exchangesPerExtraction = 5

    /// 답변 수신 후 호출. 트리거 조건을 만족하면 백그라운드로 단서를 추출·적재한다(fire-and-forget).
    /// 답변 흐름과 독립이라 실패해도 사용자 경험엔 영향이 없다.
    /// - Parameters:
    ///   - noteId: 단서를 묶을 노트 scope.
    ///   - exchangeText: 단서를 뽑을 교환 텍스트(피드백 본문, 또는 사용자 질문+답변).
    ///   - source: "feedback" | "chat" | "guide-chat" — 적재 출처 태깅.
    ///   - sessionId: 위젯 점프 타깃(있으면 단서에 세션 링크).
    static func maybeExtract(noteId: String, exchangeText: String, source: String, sessionId: String?) {
        let db = DatabaseService.shared
        let trimmed = exchangeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let cueCount = (try? db.dmnCueCount(noteId: noteId)) ?? 0
        let n = max(1, exchangesPerExtraction)
        let counter = bumpCounter(noteId: noteId)
        // cue가 0개면 무조건(첫 단서 보장), 아니면 N회마다 1회.
        let trigger = cueCount == 0 || counter % n == 0
        guard trigger else {
            appLogDebug("dmn", "cue extract skipped", ["note": noteId, "counter": "\(counter)", "cues": "\(cueCount)"])
            return
        }

        let payloadText = String(trimmed.prefix(4000))
        Task.detached {
            struct Req: Encodable { let text: String; let response_language: String }
            struct Res: Decodable { let keywords: [String] }
            do {
                let res: Res = try await APIClient.shared.postCodable(
                    "/feedback/cues",
                    body: Req(text: payloadText, response_language: Config.responseLanguage)
                )
                guard !res.keywords.isEmpty else {
                    appLog("dmn", "cue extract empty", ["note": noteId, "source": source])
                    return
                }
                try? db.insertDMNCues(noteId: noteId, keywords: res.keywords, source: source, sessionId: sessionId)
                appLog("dmn", "cues inserted (async)", ["note": noteId, "source": source, "n": "\(res.keywords.count)"])
            } catch {
                appLogError("dmn", "cue extract failed", ["note": noteId, "source": source, "error": "\(error)"])
            }
        }
    }

    /// 노트별 교환 카운터를 1 증가시키고 갱신값을 반환한다(UserDefaults, 로컬 전용).
    private static func bumpCounter(noteId: String) -> Int {
        let key = "cueExchangeCount.\(noteId)"
        let next = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(next, forKey: key)
        return next
    }
}
