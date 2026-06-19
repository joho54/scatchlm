import UIKit
import WebKit

/// KaTeX 마크다운을 **한 번 렌더해 비트맵으로 굽는** 앱 전역 공유 렌더러.
///
/// 배경: 채팅 버블·캔버스/리더 카드가 콘텐츠마다 WKWebView를 1개씩 만들어 WebContent 프로세스가
/// 누적됐다(동시 15+ → iPhone SE jetsam → "튕김"). KaTeX 출력은 (content,width,dark)이 같으면
/// 불변이므로 **살아있는 WKWebView를 이 렌더러 1개로 고정**하고, 결과 UIImage를 캐시·표시한다.
/// 채팅과 캔버스가 모두 이 렌더러를 쓰므로 두 표면이 한 번에 해결된다.
///
/// 모든 진입점은 메인 스레드 전제(SwiftUI Task @MainActor / UIView layout / WebKit 콜백).
final class KaTeXSnapshotRenderer: NSObject, WKScriptMessageHandler {
    static let shared = KaTeXSnapshotRenderer()

    private final class Job {
        let key: NSString
        let content: String
        let fontSize: CGFloat
        let width: CGFloat
        let dark: Bool
        var conts: [(UIImage?) -> Void]
        init(key: NSString, content: String, fontSize: CGFloat, width: CGFloat, dark: Bool,
             cont: @escaping (UIImage?) -> Void) {
            self.key = key; self.content = content; self.fontSize = fontSize
            self.width = width; self.dark = dark; self.conts = [cont]
        }
    }

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        c.totalCostLimit = 64 * 1024 * 1024   // 64MB — 큰 이미지 누적으로 인한 jetsam 방지(byte 단위 LRU).
        return c
    }()

    /// 이미지 메모리 추정(byte) — NSCache cost. 픽셀 수 × 4(RGBA). scale 반영(size는 point).
    private func cost(of image: UIImage) -> Int {
        let px = image.size.width * image.size.height * image.scale * image.scale
        return Int(px) * 4
    }

    private var webView: WKWebView?
    private var queue: [Job] = []
    private var active: Job?
    private var timeoutWork: DispatchWorkItem?

    private static func key(_ content: String, _ fontSize: CGFloat, _ width: CGFloat, _ dark: Bool) -> NSString {
        "\(Int(fontSize))|\(Int(width.rounded()))|\(dark ? 1 : 0)|\(content)" as NSString
    }

    /// 캐시 히트면 동기 반환(스크롤 재등장 시 깜빡임 없음).
    func cachedImage(content: String, fontSize: CGFloat, width: CGFloat, dark: Bool) -> UIImage? {
        cache.object(forKey: Self.key(content, fontSize, width, dark))
    }

    /// (content,fontSize,width,dark) KaTeX 스냅샷. 캐시/진행중 작업과 합류(coalesce).
    func image(content: String, fontSize: CGFloat, width: CGFloat, dark: Bool) async -> UIImage? {
        let key = Self.key(content, fontSize, width, dark)
        if let img = cache.object(forKey: key) { return img }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let resume: (UIImage?) -> Void = { cont.resume(returning: $0) }
            if let active, active.key == key {
                active.conts.append(resume)
            } else if let i = queue.firstIndex(where: { $0.key == key }) {
                queue[i].conts.append(resume)
            } else {
                queue.append(Job(key: key, content: content, fontSize: fontSize, width: width, dark: dark, cont: resume))
                pump()
            }
        }
    }

    // MARK: - 직렬 처리

    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        active = job
        startRender(job)
    }

    private func startRender(_ job: Job) {
        guard let webView = ensureWebView() else { complete(job, nil); return }
        webView.overrideUserInterfaceStyle = job.dark ? .dark : .light
        // 콘텐츠가 full로 페인팅되도록 충분히 큰 높이로 잡는다. 1px이면 1px 영역만 그려져
        // 스냅샷이 빈 이미지가 된다(실패 원인). 실제 높이는 스냅샷 rect로 잘라낸다.
        webView.frame = CGRect(x: 0, y: 0, width: job.width, height: 20000)

        guard let html = BakedMarkdownHTML.make(content: job.content, fontSize: job.fontSize, width: job.width),
              let baseURL = BakedMarkdownHTML.assetsBaseURL else {
            appLogError("katex", "make failed", ["w": "\(Int(job.width))"])
            complete(job, nil); return
        }
        webView.loadHTMLString(html, baseURL: baseURL)

        // 안전망 — katexReady 신호가 안 와도 2.5s 뒤 현재 높이로 강제 스냅샷.
        let timeout = DispatchWorkItem { [weak self] in self?.snapshot() }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
    }

    /// JS "렌더 완료"(katexReady) — 폰트+2프레임 후. 이때 스냅샷이 가장 안정적.
    /// body는 {h, iw(innerWidth), sw(scrollWidth)} — iw가 job.width와 같아야 폭이 맞은 것.
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "katexReady", let job = active,
              let body = message.body as? [String: Any],
              let h = (body["h"] as? NSNumber).map({ CGFloat(truncating: $0) }) else { return }
        guard h > 0 else { return }
        snapshot(height: h)
    }

    private func snapshot(height: CGFloat? = nil) {
        timeoutWork?.cancel(); timeoutWork = nil
        guard let job = active, let webView else { return }
        let raw = height ?? webView.scrollView.contentSize.height
        guard raw > 0 else { complete(job, nil); return }
        // 방어적 상한 — 비정상적으로 큰 높이(측정 버그/극단 콘텐츠)가 수백 MB 이미지로 jetsam을
        // 일으키는 것을 막는다. 실제 콘텐츠는 이보다 작다(초과 시 하단 약간 잘릴 뿐, 크래시보단 낫다).
        let h = min(raw, 12000)
        if raw > 12000 { appLogWarn("katex", "height clamped", ["raw": "\(Int(raw))", "w": "\(Int(job.width))"]) }

        // frame은 이미 충분히 큰(20000) 상태 — 콘텐츠는 상단에 full 페인팅돼 있다. 그 상단 h만 캡처.
        // 마지막 줄 descender/줄높이 잘림 방지 여유(아래는 투명). 한 줄 높이(~1.6×font)면 충분.
        let pad = ceil(job.fontSize * 1.6)
        let size = CGSize(width: job.width, height: h + pad)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(origin: .zero, size: size)
        cfg.afterScreenUpdates = true
        // 한 프레임 양보 후 캡처 — 페인트가 확실히 반영되게.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.active === job else { return }
            webView.takeSnapshot(with: cfg) { [weak self] image, error in
                guard let self else { return }
                if let error { appLogError("katex", "snapshot failed", ["error": "\(error)"]) }
                if let image { self.cache.setObject(image, forKey: job.key, cost: self.cost(of: image)) }
                self.complete(job, image)
            }
        }
    }

    private func complete(_ job: Job, _ image: UIImage?) {
        for cont in job.conts { cont(image) }
        if active === job {
            active = nil
            // 렌더 사이 대형 백킹스토어 해제 — webView가 (width×20000)로 idle하면 수백 MB를 쥔다.
            if queue.isEmpty { webView?.frame = .zero }
            pump()
        }
    }

    // MARK: - 영속 오프스크린 웹뷰 (앱 전역 live = 1)

    private func ensureWebView() -> WKWebView? {
        if let webView { return webView }
        // 키 윈도우(실제 합성되는 창) 뒤(index 0)에 깐다 — 숨은 윈도우는 렌더 패스를 못 받아
        // 스냅샷이 비어 나왔다. 앱 콘텐츠가 가려 사용자에겐 안 보인다.
        guard let host = keyWindow() else { return nil }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "katexReady")
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 1), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.isUserInteractionEnabled = false
        host.insertSubview(wv, at: 0)
        webView = wv
        return wv
    }

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
    }
}
