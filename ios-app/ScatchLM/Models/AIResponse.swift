import Foundation

struct AIResponse: Codable {
    let type: String
    let content: String?
    // Legacy fields
    let recognizedText: String?
    let feedback: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case type, content
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

struct TextbookListItem: Codable, Identifiable {
    let id: String
    let fileName: String
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case totalPages
    }
}

struct ChapterItem: Codable, Identifiable {
    let id: String
    let level: Int
    let title: String
    let pageStart: Int
    let pageEnd: Int
}

struct PageGuide: Codable {
    let page: Int
    let topic: String
    let content: String?
    let keyPoints: [String]?
    let exercises: [String]?
    let connections: String?
    let cached: Bool

    enum CodingKeys: String, CodingKey {
        case page, topic, content, exercises, connections, cached
        case keyPoints = "key_points"
    }
}

struct ChapterGuide: Codable {
    let chapterId: String
    let title: String
    let topic: String
    let keyConcepts: [String]
    let studyOrder: [String]
    let commonMistakes: [String]
    let summary: String
    let cached: Bool

    enum CodingKeys: String, CodingKey {
        case title, topic, summary, cached
        case chapterId = "chapter_id"
        case keyConcepts = "key_concepts"
        case studyOrder = "study_order"
        case commonMistakes = "common_mistakes"
    }
}
