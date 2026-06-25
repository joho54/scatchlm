import Foundation

/// `/api/discover` 응답 (docs/discover-feature-spec.md §3.2-a).
/// 추천 0개면 `recommendations`가 빈 배열, `note`에 솔직한 한 줄.
struct DiscoverResult: Decodable {
    let recommendations: [DiscoverItem]
    let note: String
}

/// `/api/discover/suggestions` 응답 — 서재 기반 "공부 시작점" 제안 프롬프트.
struct DiscoverSuggestions: Decodable {
    let suggestions: [String]
}

/// 추천 자료 한 건. format/level은 백엔드가 enum을 보장하지만, 미래 값 추가가
/// 응답 전체 디코딩을 깨지 않도록 String으로 받고 표시 헬퍼로 분기한다.
struct DiscoverItem: Decodable, Identifiable, Hashable {
    let title: String
    let url: String
    let format: String   // "PDF" | "웹페이지" | "강의코스"
    let level: String    // "입문" | "학부기초" | "심화" | "대학원"
    let why: String

    // url은 재검증을 통과한 살아있는 URL이라 사실상 유일 — id로 충분.
    var id: String { url }

    /// PDF 직접 다운로드 대상인가(= 서재 인제스션 가능). 그 외(웹페이지/강의코스)는 브라우저로 연다.
    var isPDF: Bool { format == "PDF" }

    var parsedURL: URL? { URL(string: url) }

    /// format 칩에 쓸 SF Symbol.
    var formatSymbol: String {
        switch format {
        case "PDF": return "doc.fill"
        case "강의코스": return "play.rectangle.fill"
        default: return "globe"
        }
    }
}
