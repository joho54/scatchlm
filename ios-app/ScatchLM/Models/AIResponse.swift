import Foundation

struct AIResponse: Codable {
    let type: String
    let recognizedText: String
    let feedback: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case type
        case recognizedText = "recognized_text"
        case feedback
        case summary
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
    let keyPoints: [String]
    let exercises: [String]
    let connections: String
    let cached: Bool

    enum CodingKeys: String, CodingKey {
        case page, topic, exercises, connections, cached
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
