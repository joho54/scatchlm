import SwiftUI
import UIKit
import WebKit

// MARK: - HTML 빌더 (SwiftUI/UIKit 공용)

/// 마크다운 + LaTeX 원문을 `template.html`(marked.js + KaTeX) 기반 HTML 문서로 굽는다.
enum BakedMarkdownHTML {
    /// 번들된 WebAssets 디렉토리 — loadHTMLString의 baseURL. 상대 경로(css/js/font) 해석용.
    static let assetsBaseURL: URL? =
        Bundle.main.url(forResource: "WebAssets", withExtension: nil)

    private static let template: String? = {
        guard let url = assetsBaseURL?.appendingPathComponent("template.html"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s
    }()

    static func make(content: String, fontSize: CGFloat) -> String? {
        guard let template else { return nil }
        let b64 = Data(content.utf8).base64EncodedString()
        return template
            .replacingOccurrences(of: "__CONTENT_B64__", with: b64)
            .replacingOccurrences(of: "__FONT_SIZE__", with: String(Int(fontSize)))
    }
}

// MARK: - SwiftUI: self-sizing (부모가 스크롤 담당)

/// 마크다운 + LaTeX 원문을 HTML로 "bake"해서 WKWebView로 렌더한다.
/// 콘텐츠 높이를 JS가 측정해 self-sizing 된다. 채팅/가이드처럼 부모 ScrollView 안에서 사용.
struct BakedMarkdownView: View {
    let content: String
    var fontSize: CGFloat = 14

    @State private var height: CGFloat = 1

    var body: some View {
        BakedMarkdownWebView(content: content, fontSize: fontSize, height: $height)
            .frame(height: height)
    }
}

private struct BakedMarkdownWebView: UIViewRepresentable {
    let content: String
    let fontSize: CGFloat
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightChanged")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.webView = webView
        loadIfNeeded(webView, context: context)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        loadIfNeeded(webView, context: context)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "heightChanged")
    }

    private func loadIfNeeded(_ webView: WKWebView, context: Context) {
        let key = "\(fontSize)|\(content)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        guard let html = BakedMarkdownHTML.make(content: content, fontSize: fontSize),
              let baseURL = BakedMarkdownHTML.assetsBaseURL else {
            webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
            return
        }
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var height: CGFloat
        var loadedKey: String?
        weak var webView: WKWebView?

        init(height: Binding<CGFloat>) { _height = height }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "heightChanged",
                  let h = message.body as? NSNumber else { return }
            let newHeight = CGFloat(truncating: h)
            guard newHeight > 0, abs(newHeight - height) > 0.5 else { return }
            DispatchQueue.main.async { self.height = newHeight }
        }
    }
}

// MARK: - UIKit: 고정 프레임 + 내부 스크롤 (캔버스 카드용)

/// 외부에서 프레임(높이)을 정해주는 환경(PencilKit 캔버스 카드 등)에서 쓰는 UIKit 변형.
/// 비동기 높이 보정 대신, 콘텐츠가 프레임을 넘치면 내부 스크롤로 처리한다.
final class BakedMarkdownUIView: UIView {
    private let webView: WKWebView

    init(content: String, fontSize: CGFloat = 14) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        webView.scrollView.isScrollEnabled = true   // 넘치면 카드 안에서 스크롤
        webView.scrollView.alwaysBounceVertical = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        if let html = BakedMarkdownHTML.make(content: content, fontSize: fontSize),
           let baseURL = BakedMarkdownHTML.assetsBaseURL {
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
