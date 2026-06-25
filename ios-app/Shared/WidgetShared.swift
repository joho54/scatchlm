import Foundation

/// 앱 ↔ 위젯 공유 데이터 계층.
///
/// 위젯은 별도 프로세스라 메인 앱의 GRDB(`scatchlm.db`)에 직접 접근하지 못한다.
/// 그래서 위젯에 필요한 "최근 인출 단서"만 App Group 공유 저장소(UserDefaults suite)에
/// 스냅샷으로 써둔다. 앱이 DMNCue를 적재할 때마다 갱신하고, 위젯은 읽기만 한다.
///
/// 전체 DB를 App Group으로 옮기지 않는 이유: 위젯엔 keyword + 딥링크 타깃만 있으면 충분하고,
/// DB 파일 위치 이전은 기존 사용자 마이그레이션 리스크가 크다.

/// 위젯에 표시할 단일 인출 단서. DMNCue의 위젯용 투영(projection).
public struct WidgetCue: Codable, Identifiable, Hashable {
    public var id: String          // DMNCue.id
    public var keyword: String
    public var sessionId: String?  // 점프 타깃(세션 시트). 레거시 카드는 nil → 점프 불가
    public var noteId: String
    public var createdAt: Date

    public init(id: String, keyword: String, sessionId: String?, noteId: String, createdAt: Date) {
        self.id = id
        self.keyword = keyword
        self.sessionId = sessionId
        self.noteId = noteId
        self.createdAt = createdAt
    }
}

public enum WidgetShared {
    /// App Group ID — 앱·위젯 양쪽 엔타이틀먼트에 동일하게 등록.
    public static let appGroupID = "group.com.joho54.scatchlm"

    /// 위젯 딥링크 URL scheme. onOpenURL에서 파싱.
    public static let urlScheme = "scatchlm"

    private static let cuesKey = "widget.recentCues"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// 최근 단서 스냅샷을 공유 저장소에 기록한다(앱 → 위젯).
    public static func writeCues(_ cues: [WidgetCue]) {
        guard let defaults else { return }
        if let data = try? JSONEncoder.shared.encode(cues) {
            defaults.set(data, forKey: cuesKey)
        }
    }

    /// 공유 저장소에서 최근 단서를 읽는다(위젯). 없으면 빈 배열.
    public static func readCues() -> [WidgetCue] {
        guard let defaults, let data = defaults.data(forKey: cuesKey) else { return [] }
        return (try? JSONDecoder.shared.decode([WidgetCue].self, from: data)) ?? []
    }

    /// 위젯 딥링크 URL을 만든다. 세션이 있으면 세션 시트로, 없으면 노트로 폴백.
    public static func deepLink(for cue: WidgetCue) -> URL? {
        if let sid = cue.sessionId, !sid.isEmpty {
            return URL(string: "\(urlScheme)://session/\(sid)?note=\(cue.noteId)")
        }
        return URL(string: "\(urlScheme)://note/\(cue.noteId)")
    }
}

private extension JSONEncoder {
    static let shared: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let shared: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
