import Foundation

/// 피드백 본문에서 DMN 타이머에 띄울 "단어 조각"을 룰 베이스로 추출한다.
///
/// 의미 분석/임베딩 없이 마크다운 제거 → 토큰화 → 불용어·길이·숫자 필터 → 빈도 랭킹만 쓴다.
/// 외국어(고전어 포함)·전공 용어가 섞이므로 언어 의존 형태소 분석은 피하고, 한국어 조사만
/// 가볍게 떼어낸다. 결과는 빈도 내림차순으로 정렬하되, 호출부에서 슬라이드 순서를 섞어 쓴다.
enum WordExtractor {

    /// 여러 피드백 본문을 합쳐 상위 단어를 추출한다.
    /// - Parameters:
    ///   - contents: 피드백 content 배열 (최신 → 과거 순서 무관).
    ///   - limit: 반환할 최대 단어 수.
    static func importantWords(from contents: [String], limit: Int = 40) -> [String] {
        var counts: [String: Int] = [:]      // 소문자 키 → 빈도
        var display: [String: String] = [:]   // 소문자 키 → 첫 등장 원형(표시용)

        for raw in contents {
            let cleaned = stripMarkdown(raw)
            for token in tokenize(cleaned) {
                let word = normalizeKorean(token)
                guard isMeaningful(word) else { continue }
                let key = word.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = word }
            }
        }

        // 빈도 내림차순 → 동률이면 단어 길이 내림차순(더 구체적인 용어 우선).
        let ranked = counts.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            return (display[a.key]?.count ?? 0) > (display[b.key]?.count ?? 0)
        }
        return ranked.prefix(limit).compactMap { display[$0.key] }
    }

    // MARK: - 마크다운/마크업 제거

    private static func stripMarkdown(_ text: String) -> String {
        var s = text
        // 코드블록/인라인코드
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        // 이미지/링크 → 표시 텍스트만 남김
        s = s.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        // 인라인 LaTeX/수식
        s = s.replacingOccurrences(of: "\\$[^$]*\\$", with: " ", options: .regularExpression)
        // 강조/헤더/인용/리스트 마커 등 마크업 문자
        s = s.replacingOccurrences(of: "[#>*_~`|\\-]+", with: " ", options: .regularExpression)
        return s
    }

    // MARK: - 토큰화

    /// 문자(letter)·숫자 시퀀스만 토큰으로 끊는다. CJK·라틴·그리스 등 유니코드 letter 전반 허용.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - 한국어 조사 제거(가벼운 휴리스틱)

    /// 토큰 끝의 흔한 1~2글자 조사를 보수적으로 떼어낸다. 어근이 너무 짧아지지 않을 때만.
    private static func normalizeKorean(_ token: String) -> String {
        guard token.count >= 3, isHangul(token) else { return token }
        for josa in josaSuffixes {
            if token.hasSuffix(josa) {
                let stem = String(token.dropLast(josa.count))
                if stem.count >= 2 { return stem }
            }
        }
        return token
    }

    private static func isHangul(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }
    }

    // MARK: - 필터

    private static func isMeaningful(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        // 순수 숫자 제외
        if word.allSatisfy({ $0.isNumber }) { return false }
        if stopwords.contains(word.lowercased()) { return false }
        return true
    }

    // MARK: - 불용어 / 조사 사전

    private static let josaSuffixes: [String] = [
        "으로써", "으로서", "에서는", "에게서", "이라고", "라고는",
        "에서", "에게", "한테", "으로", "이라", "라는", "라고", "처럼", "보다", "까지", "부터", "마다", "조차", "마저",
        "은", "는", "이", "가", "을", "를", "에", "의", "도", "와", "과", "로", "만", "랑", "나"
    ]

    /// 한국어 + 영어 흔한 불용어. 의미 빈약한 기능어/연결어 위주.
    private static let stopwords: Set<String> = [
        // 한국어
        "그리고", "그러나", "그래서", "하지만", "또는", "또한", "그런데", "따라서", "때문", "때문에",
        "이것", "그것", "저것", "여기", "거기", "저기", "이런", "그런", "저런", "어떤", "무엇",
        "정도", "경우", "사용", "통해", "위해", "대해", "관련", "다음", "이전", "현재", "내용",
        "있다", "없다", "이다", "한다", "된다", "같다", "보다", "하는", "되는", "있는", "없는",
        "수가", "것을", "것이", "것은", "당신", "우리", "에서", "으로", "그냥", "약간", "조금",
        "표현", "단어", "문장", "부분", "설명", "의미", "이해", "정리", "확인", "참고",
        // 영어
        "the", "and", "for", "are", "but", "not", "you", "all", "can", "her", "was", "one", "our",
        "out", "his", "has", "had", "how", "its", "who", "did", "yes", "this", "that", "with",
        "from", "they", "have", "what", "your", "when", "will", "there", "their", "would", "could",
        "should", "about", "which", "these", "those", "than", "then", "them", "also", "into", "such",
        "very", "just", "some", "more", "most", "like", "here", "word", "note", "text"
    ]
}
