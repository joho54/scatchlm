import SwiftUI

/// 캔버스 배경 템플릿. 노트 단위 속성(`Note.template`)으로 저장·동기화된다.
/// rawValue가 DB 컬럼/sync 와이어 문자열이므로 케이스 이름을 바꾸면 마이그레이션이 필요하다.
/// 새 템플릿은 케이스만 추가하면 picker·렌더링에 자동 반영된다(forward-compatible).
enum NoteTemplate: String, CaseIterable, Identifiable {
    case blank   // 빈 종이 (기존 기본값)
    case lined   // 줄노트 — 수평선
    case grid    // 격자(모눈) — 수평+수직선
    case staff   // 오선지 — 5줄 묶음

    var id: String { rawValue }

    /// 저장된 문자열에서 복원 — 미지의 값은 blank로 폴백(앞으로 추가될 케이스에 대한 forward-compat).
    init(storage: String) {
        self = NoteTemplate(rawValue: storage) ?? .blank
    }

    var displayName: String {
        switch self {
        case .blank: return String(localized: "기본")
        case .lined: return String(localized: "줄노트")
        case .grid:  return String(localized: "격자")
        case .staff: return String(localized: "오선지")
        }
    }

    var systemImage: String {
        switch self {
        case .blank: return "rectangle"
        case .lined: return "line.3.horizontal"
        case .grid:  return "grid"
        case .staff: return "music.note"
        }
    }

    /// 선 간격·굵기·농도 등 렌더 파라미터(논리좌표 pt). CanvasTemplateLayer가 소비한다.
    struct Metrics {
        /// 줄노트/격자의 행 간격(격자는 열 간격도 동일).
        var rowHeight: CGFloat = 36
        /// 오선 5줄 사이 간격.
        var staffGap: CGFloat = 9
        /// 오선 묶음 사이(및 상단) 여백.
        var groupGap: CGFloat = 36
        var lineWidth: CGFloat = 0.75
        /// 잉크 위에서 너무 튀지 않도록 낮은 농도. 잉크색(다크=흰/라이트=검)에 곱해진다.
        var opacity: CGFloat = 0.16
    }

    var metrics: Metrics {
        switch self {
        case .blank: return Metrics()
        case .lined: return Metrics(rowHeight: 40, lineWidth: 0.75, opacity: 0.16)
        case .grid:  return Metrics(rowHeight: 28, lineWidth: 0.6, opacity: 0.14)
        case .staff: return Metrics(staffGap: 9, groupGap: 36, lineWidth: 0.75, opacity: 0.22)
        }
    }
}
