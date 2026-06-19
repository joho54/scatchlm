import SwiftUI
import UIKit
import WebKit
import MarkdownUI

// MARK: - HTML 빌더 (렌더러 공용)

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

    /// width=nil → viewport `device-width`(프레임 폭에 적응, 라이브 webview용).
    /// width 지정 → 그 폭으로 못 박음(스냅샷 폭과 일치, bake 렌더러용).
    static func make(content: String, fontSize: CGFloat, width: CGFloat? = nil) -> String? {
        guard let template else { return nil }
        return bake(template: template, content: content, fontSize: fontSize, width: width)
    }

    /// 순수 치환 — 번들 의존 없이 테스트 가능. content는 base64로 인코딩해 HTML 이스케이프 이슈 회피.
    static func bake(template: String, content: String, fontSize: CGFloat, width: CGFloat?) -> String {
        let b64 = Data(content.utf8).base64EncodedString()
        let widthValue = width.map { String(Int($0.rounded())) } ?? "device-width"
        return template
            .replacingOccurrences(of: "__CONTENT_B64__", with: b64)
            .replacingOccurrences(of: "__FONT_SIZE__", with: String(Int(fontSize)))
            .replacingOccurrences(of: "__WIDTH__", with: widthValue)
    }
}

// MARK: - SwiftUI: 스냅샷 이미지 백업 (채팅/가이드 — 부모 ScrollView 안)

/// KaTeX를 `KaTeXSnapshotRenderer`(공유 단일 webview)로 한 번 굽고 결과 비트맵을 표시한다.
/// 버블마다 webview를 만들지 않아 WebContent 프로세스 누적이 없다.
/// 렌더 대기 중에는 네이티브 MarkdownUI로 표시(텍스트는 보이고 수식만 원문) → 캐시 적중 시 즉시 교체.
struct BakedMarkdownView: View {
    let content: String
    var fontSize: CGFloat = 14

    @Environment(\.colorScheme) private var colorScheme
    /// 채팅 컨테이너가 1회 측정해 주입하는 콘텐츠 폭. per-bubble GeometryReader/preference 측정을
    /// 없애 키보드 등장 시 N개 버블이 동시에 재측정·재정렬하며 메인 스레드를 막던 App Hang을 차단한다.
    @Environment(\.bakeWidth) private var injectedWidth
    @State private var image: UIImage?
    @State private var renderWidth: CGFloat = 0
    @State private var renderDark: Bool?

    /// 주입 폭이 있으면 그걸로, 없으면 합리적 기본값(채팅 밖 단독 사용 대비).
    private var width: CGFloat { injectedWidth > 1 ? injectedWidth : 360 }

    var body: some View {
        Group {
            if let image {
                // scaledToFit — 렌더 폭과 실제 슬롯이 약간 달라도 슬롯에 맞춰 스케일(±소량). per-bubble
                // GeometryReader가 없어 이전의 폭 붕괴 루프는 발생하지 않는다.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(content)
            } else {
                // 렌더 대기 폴백 — 가벼운 plain Text(수식은 원문).
                Text(content)
                    .font(.system(size: fontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { request() }
        .onChange(of: width) { _, _ in request() }
        .onChange(of: colorScheme) { _, _ in request(force: true) }
    }

    private func request(force: Bool = false) {
        let w = width.rounded()
        guard w > 1 else { return }
        let dark = colorScheme == .dark
        if !force, w == renderWidth, renderDark == dark { return }
        renderWidth = w
        renderDark = dark
        if let cached = KaTeXSnapshotRenderer.shared.cachedImage(content: content, fontSize: fontSize, width: w, dark: dark) {
            image = cached
            return
        }
        Task { @MainActor in
            let img = await KaTeXSnapshotRenderer.shared.image(content: content, fontSize: fontSize, width: w, dark: dark)
            // 그새 width/dark가 또 바뀌었으면 최신 요청이 갱신하도록 stale 결과는 버림.
            guard w == renderWidth, (colorScheme == .dark) == renderDark, let img else { return }
            image = img
        }
    }
}

// 채팅 컨테이너 → 버블로 콘텐츠 폭을 1회 주입(per-bubble 측정 제거).
private struct BakeWidthEnvKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var bakeWidth: CGFloat {
        get { self[BakeWidthEnvKey.self] }
        set { self[BakeWidthEnvKey.self] = newValue }
    }
}

extension View {
    /// 콘텐츠 폭을 **1회** 측정해 자식 BakedMarkdownView에 주입한다. 버블 chrome(padding 등)을
    /// inset으로 뺀 값이 bake 렌더 폭이 된다. 측정용 GeometryReader는 컨테이너당 1개뿐이라,
    /// 키보드 등장(높이만 변함)엔 재발화하지 않아 per-bubble 재측정 폭주가 사라진다.
    func injectBakeWidth(inset: CGFloat = 24) -> some View {
        modifier(BakeWidthInjector(inset: inset))
    }
}

private struct BakeWidthInjector: ViewModifier {
    let inset: CGFloat
    @State private var width: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .environment(\.bakeWidth, max(0, width - inset))
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { width = g.size.width }
                        .onChange(of: g.size.width) { _, w in width = w }
                }
            )
    }
}

// MARK: - UIKit: 고정 프레임 + 내부 스크롤 (캔버스/리더 카드용)

/// 외부에서 프레임(높이)을 정해주는 환경(PencilKit 캔버스 카드 등)용 UIKit 변형.
/// **bake가 아니라 라이브 WKWebView** — 카드는 고정 프레임 + 내부 스크롤이라, 전체 콘텐츠를 한 장
/// 이미지로 구우면(예: 692×4768@2x ≈ 50MB) 메모리가 폭발한다. 카드는 수가 적고 보이는 영역만
/// 렌더하면 충분하므로 webview로 둔다(채팅처럼 버블 多 누적이 없어 안전). viewport=device-width.
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
