import SwiftUI

/// 캔버스 배경 템플릿. 노트 단위 속성(`Note.template`)으로 저장·동기화된다.
/// rawValue가 DB 컬럼/sync 와이어 문자열이므로 케이스 이름을 바꾸면 마이그레이션이 필요하다.
/// 새 템플릿은 케이스만 추가하면 picker·렌더링에 자동 반영된다(forward-compatible).
enum NoteTemplate: String, CaseIterable, Identifiable {
    case blank       // 빈 종이 (기존 기본값)
    case lined       // 줄노트 — 수평선
    case grid        // 격자(모눈) — 수평+수직선
    case dotgrid     // 도트 그리드 — 격자 교점에 점
    case manuscript  // 원고지 — 글자 한 칸씩 정사각 칸
    case fourline    // 영어 4선 — 4줄 묶음(가운데 x-height 점선)
    case staff       // 오선지 — 5줄 묶음
    case cornell     // 코넬 — 좌측 단서칸 세로 구분선 + 본문 줄(하단 요약밴드는 무한캔버스라 생략)

    var id: String { rawValue }

    /// 저장된 문자열에서 복원 — 미지의 값은 blank로 폴백(앞으로 추가될 케이스에 대한 forward-compat).
    init(storage: String) {
        self = NoteTemplate(rawValue: storage) ?? .blank
    }

    /// 배경 선을 AI 피드백 이미지에 함께 렌더할지 여부.
    /// "쓰기 교정"용(오선지·영어 4선·원고지)은 선이 음높이·baseline·칸 같은 컨텍스트라 포함하고,
    /// "필기 정리"용(줄노트·격자·도트·코넬)은 OCR 노이즈가 되므로 잉크만 보낸다.
    var includesLinesInFeedback: Bool {
        switch self {
        case .staff, .fourline, .manuscript: return true
        case .blank, .lined, .grid, .dotgrid, .cornell: return false
        }
    }

    var displayName: String {
        switch self {
        case .blank:      return String(localized: "기본")
        case .lined:      return String(localized: "줄노트")
        case .grid:       return String(localized: "격자")
        case .dotgrid:    return String(localized: "도트")
        case .manuscript: return String(localized: "원고지")
        case .fourline:   return String(localized: "영어 4선")
        case .staff:      return String(localized: "오선지")
        case .cornell:    return String(localized: "코넬")
        }
    }

    var systemImage: String {
        switch self {
        case .blank:      return "rectangle"
        case .lined:      return "line.3.horizontal"
        case .grid:       return "grid"
        case .dotgrid:    return "circle.grid.3x3"
        case .manuscript: return "square.grid.3x3"
        case .fourline:   return "textformat.abc"
        case .staff:      return "music.note"
        case .cornell:    return "rectangle.split.2x1"
        }
    }

    /// 선 간격·굵기·농도 등 렌더 파라미터(논리좌표 pt). CanvasTemplateLayer가 소비한다.
    struct Metrics {
        /// 줄노트/격자/원고지/도트의 행(·열) 간격.
        var rowHeight: CGFloat = 36
        /// 묶음형(오선/4선)에서 묶음 내 선 사이 간격.
        var staffGap: CGFloat = 9
        /// 묶음형에서 묶음 사이(및 상단) 여백.
        var groupGap: CGFloat = 36
        var lineWidth: CGFloat = 0.75
        /// 잉크 위에서 너무 튀지 않도록 낮은 농도. 잉크색(다크=흰/라이트=검)에 곱해진다.
        var opacity: CGFloat = 0.16
        /// 도트 그리드의 점 반지름. 0이면 점 없음.
        var dotRadius: CGFloat = 0
        /// 코넬 단서칸 세로 구분선의 x 위치(논리폭 대비 비율). 0이면 구분선 없음.
        var cueFraction: CGFloat = 0
    }

    var metrics: Metrics {
        switch self {
        case .blank:      return Metrics()
        case .lined:      return Metrics(rowHeight: 40, lineWidth: 0.75, opacity: 0.16)
        case .grid:       return Metrics(rowHeight: 28, lineWidth: 0.6, opacity: 0.14)
        case .dotgrid:    return Metrics(rowHeight: 26, lineWidth: 0, opacity: 0.30, dotRadius: 1.2)
        case .manuscript: return Metrics(rowHeight: 34, lineWidth: 0.6, opacity: 0.16)
        case .fourline:   return Metrics(staffGap: 7, groupGap: 22, lineWidth: 0.7, opacity: 0.18)
        case .staff:      return Metrics(staffGap: 9, groupGap: 36, lineWidth: 0.75, opacity: 0.22)
        case .cornell:    return Metrics(rowHeight: 40, lineWidth: 0.7, opacity: 0.16, cueFraction: 0.28)
        }
    }
}
