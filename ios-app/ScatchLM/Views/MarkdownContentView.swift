import SwiftUI
import MarkdownUI

/// 콘텐츠 + 설정(Config.mathRenderMode)에 따라 렌더러를 고른다.
/// - KaTeX 경로: BakedMarkdownView (WKWebView, 수식 렌더)
/// - 네이티브 경로: MarkdownUI (가볍고 빠름, 수식 미렌더)
enum MarkdownRender {
    /// 주어진 콘텐츠를 KaTeX(HTML)로 렌더할지 결정.
    static func shouldUseKaTeX(_ content: String) -> Bool {
        switch Config.mathRenderMode {
        case .on:  return true
        case .off: return false
        case .auto: return containsMath(content)
        }
    }

    /// LaTeX 수식 존재 휴리스틱 (순수 함수).
    /// 통화 표기($5 등) 오인을 피하려고, 단일 `$...$`는 내부에 수식 문자(`\ ^ _ {`)가
    /// 있을 때만 수식으로 본다.
    static func containsMath(_ s: String) -> Bool {
        if s.contains("$$") { return true }                 // 디스플레이 수식
        if s.contains("\\(") || s.contains("\\[") { return true } // \(...\), \[...\]
        // \frac, \alpha 같은 백슬래시 명령
        if s.range(of: "\\\\[a-zA-Z]+", options: .regularExpression) != nil { return true }
        // 수식 문자를 포함한 $...$ 쌍 (통화 $5 → 매칭 안 됨)
        if s.range(of: "\\$[^$\\n]*[\\\\^_{][^$\\n]*\\$", options: .regularExpression) != nil { return true }
        return false
    }
}

/// 피드백/채팅/가이드 본문 렌더 — 설정·콘텐츠에 따라 KaTeX 또는 네이티브 선택.
struct MarkdownContentView: View {
    let content: String
    var fontSize: CGFloat = 14

    var body: some View {
        if MarkdownRender.shouldUseKaTeX(content) {
            BakedMarkdownView(content: content, fontSize: fontSize)
        } else {
            Markdown(content)
                .markdownTextStyle { FontSize(fontSize) }
        }
    }
}
