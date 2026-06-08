import Foundation

struct AIResponse: Codable {
    let type: String
    let content: String?
    let feedbackId: String?
    // Legacy fields
    let recognizedText: String?
    let feedback: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case type, content
        case feedbackId = "feedback_id"
        case recognizedText = "recognized_text"
        case feedback
        case summary
    }

    /// 표시용 텍스트 — content 우선, legacy fallback
    var displayText: String {
        if let content, !content.isEmpty {
            return content
        }
        var parts: [String] = []
        if let r = recognizedText, !r.isEmpty { parts.append("📝 \(r)") }
        if let f = feedback, !f.isEmpty { parts.append(f) }
        if let s = summary, !s.isEmpty { parts.append("💡 \(s)") }
        return parts.joined(separator: "\n\n")
    }
}

struct TextbookListItem: Codable, Identifiable, Hashable {
    let id: String
    let fileName: String
    let totalPages: Int
    let isScanned: Bool
    let ocrStatus: String?
    let ocrPagesDone: Int
    let ocrPagesTotal: Int

    enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case totalPages
        case isScanned = "is_scanned"
        case ocrStatus = "ocr_status"
        case ocrPagesDone = "ocr_pages_done"
        case ocrPagesTotal = "ocr_pages_total"
    }

    init(id: String, fileName: String, totalPages: Int,
         isScanned: Bool = false, ocrStatus: String? = nil,
         ocrPagesDone: Int = 0, ocrPagesTotal: Int = 0) {
        self.id = id
        self.fileName = fileName
        self.totalPages = totalPages
        self.isScanned = isScanned
        self.ocrStatus = ocrStatus
        self.ocrPagesDone = ocrPagesDone
        self.ocrPagesTotal = ocrPagesTotal
    }

    /// 교재 목록에 띄울 OCR 상태 칩 텍스트(완료/텍스트PDF면 nil).
    var ocrChip: String? {
        guard isScanned else { return nil }
        switch ocrStatus {
        case "complete", .none:
            return nil
        case "paused", "error":
            return String(localized: "인식 대기 중")
        default:  // pending / running
            return ocrPagesTotal > 0
                ? String(localized: "인식 중 \(ocrPagesDone)/\(ocrPagesTotal)")
                : String(localized: "인식 중…")
        }
    }
}

struct ChapterItem: Codable, Identifiable {
    let id: String
    let level: Int
    let title: String
    let pageStart: Int
    let pageEnd: Int

    /// page를 포함하는 가장 좁은(level≥1, 페이지 범위가 가장 작은) 챕터를 찾는다 (§4.2).
    /// 표시 시점에 세션의 `anchorPage`를 챕터로 매핑하는 데 쓴다. 매칭 실패 시 nil.
    static func narrowest(for page: Int, in chapters: [ChapterItem]) -> ChapterItem? {
        chapters
            .filter { $0.level >= 1 && page >= $0.pageStart && page <= $0.pageEnd }
            .min { ($0.pageEnd - $0.pageStart) < ($1.pageEnd - $1.pageStart) }
    }
}

struct PageGuide: Codable {
    let page: Int
    let topic: String
    let content: String?
    let keyPoints: [String]?
    let exercises: [String]?
    let connections: String?
    let cached: Bool
    let feedbackId: String?

    enum CodingKeys: String, CodingKey {
        case page, topic, content, exercises, connections, cached
        case keyPoints = "key_points"
        case feedbackId = "feedback_id"
    }
}

/// 스캔본 PDF OCR/인덱싱 진행 상태 (GET /api/pdf/{id}/status, scanned-pdf-ocr-spec §3.2-b).
struct PdfStatus: Decodable {
    let isScanned: Bool
    let ocrStatus: String?      // pending|running|paused|capped|complete (텍스트 PDF는 nil)
    let ocrPagesDone: Int
    let ocrPagesTotal: Int
    let totalPages: Int
    let capped: Bool
    let capLimit: Int?
    let chaptersReady: Bool

    enum CodingKeys: String, CodingKey {
        case isScanned = "is_scanned"
        case ocrStatus = "ocr_status"
        case ocrPagesDone = "ocr_pages_done"
        case ocrPagesTotal = "ocr_pages_total"
        case totalPages = "total_pages"
        case capped
        case capLimit = "cap_limit"
        case chaptersReady = "chapters_ready"
    }

    /// OCR가 아직 진행 중(폴링 지속 필요)인가.
    var isProcessing: Bool {
        isScanned && (ocrStatus == "pending" || ocrStatus == "running" || ocrStatus == "paused")
    }
}

/// 가이드 요청이 OCR 미완으로 막힌 경우(409 ocr_incomplete, §3.2-c).
struct OcrIncompleteInfo: Decodable {
    let code: String
    let ocrStatus: String?
    let capped: Bool
    let page: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case ocrStatus = "ocr_status"
        case capped
        case page
    }

    static func decode(from data: Data) -> OcrIncompleteInfo? {
        if let info = try? JSONDecoder().decode(OcrIncompleteInfo.self, from: data), info.code == "ocr_incomplete" {
            return info
        }
        struct Wrapper: Decodable { let detail: OcrIncompleteInfo }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: data), w.detail.code == "ocr_incomplete" {
            return w.detail
        }
        return nil
    }
}

struct ChapterGuide: Codable {
    let chapterId: String
    let title: String
    let pageStart: Int
    let pageEnd: Int
    let topic: String
    let keyConcepts: [String]
    let studyOrder: [String]
    let commonMistakes: [String]
    let summary: String
    let cached: Bool
    let feedbackId: String?

    enum CodingKeys: String, CodingKey {
        case title, topic, summary, cached
        case chapterId = "chapter_id"
        case pageStart = "page_start"
        case pageEnd = "page_end"
        case keyConcepts = "key_concepts"
        case studyOrder = "study_order"
        case commonMistakes = "common_mistakes"
        case feedbackId = "feedback_id"
    }
}
