import SwiftUI
import SafariServices

/// SFSafariViewController 래퍼 — discover의 웹페이지/강의코스 항목을 인앱 브라우저로 연다
/// (docs/discover-feature-spec.md §4.2 Track C: 인제스션 아님, 외부 열람).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
