import Foundation

/// 피드백 본문에서 DMN 휴식 타이머에 띄울 "단서(cue)"를 뽑는다.
///
/// 중요도를 룰(불용어/빈도)로 *추정*하지 않는다 — 피드백을 생성한 LLM이 이미 굵게(**bold**)
/// 강조해 둔 부분을 그대로 단서로 쓴다. 즉 "무엇이 중요한가"는 모델이 판단하고, 여기서는
/// 그 강조 스팬을 *기계적으로* 추출하기만 한다(짧은 것만 골라 중복 제거). 의미 판단이 규칙에
/// 들어가지 않으므로 언어/주제에 안 깨진다.
enum WordExtractor {

    /// 최근 → 과거 순서의 피드백 본문에서 굵게 강조된 짧은 단서를 추출한다.
    /// 최신 피드백의 단서가 앞에 오도록 입력 순서를 유지하고 중복만 제거한다.
    static func importantWords(from contents: [String], limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for content in contents {
            for span in boldSpans(in: content) {
                let cue = clean(span)
                guard isShortCue(cue) else { continue }
                if seen.insert(cue.lowercased()).inserted {
                    result.append(cue)
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }

    /// `**...**` 및 `__...__` 강조 스팬의 내부 텍스트.
    private static func boldSpans(in text: String) -> [String] {
        var spans: [String] = []
        let ns = text as NSString
        for pattern in ["\\*\\*(.+?)\\*\\*", "__(.+?)__"] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let m = match, m.numberOfRanges > 1 else { return }
                spans.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return spans
    }

    /// 내부 잔여 마크다운·양끝 구두점/공백 제거.
    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let edgePunct = CharacterSet(charactersIn: ".,!?;:·…\"'“”‘’()[]")
        t = t.trimmingCharacters(in: edgePunct)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 짧은 단어조각만 — 5자 이하. 구절/문장을 굵게 친 것은 주변 단서엔 너무 길어 제외.
    private static func isShortCue(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 5 else { return false }
        // 글자가 하나도 없는(순수 숫자/기호) 스팬 제외
        return s.contains { $0.isLetter }
    }
}
