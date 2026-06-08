import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// `UIDocumentPickerViewController(asCopy: true)` 래퍼.
///
/// SwiftUI `.fileImporter`는 asCopy를 지원하지 않아, 클라우드 File Provider(OneDrive·iCloud
/// Drive 등)의 **미다운로드(placeholder)** 파일을 security-scoped 원본 URL로 넘긴다. 그 URL을
/// 비조정 `Data(contentsOf:)`로 읽으면 바이트가 로컬에 없어 `ENOENT`(NSCocoaError 260 /
/// POSIX 2)로 실패한다 — 운영에서 신규 사용자가 OneDrive 교재 업로드에 실패해 이탈한 사례의 원인.
///
/// `asCopy: true`는 시스템이 파일을 **다운로드 + 앱 샌드박스로 복사**한 로컬 사본 URL을 주므로
/// materialize가 보장되고 security-scope 처리도 불필요하다. 호출부는 받은 URL을 그대로 읽으면 된다.
/// (다운로드가 끝내 실패하면(오프라인 등) 시스템 피커가 자체 처리하거나, 이후 읽기 실패로 이어져
///  호출부 catch에서 사용자에게 안내한다.)
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    /// 선택된 로컬 사본 URL(앱 tmp). 호출부가 이 URL로 바로 업로드.
    let onPick: (URL) -> Void
    /// 시스템 Cancel 등으로 선택 없이 닫힘.
    var onCancel: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { parent.onCancel?(); return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel?()
        }
    }
}
