import Foundation

/// 원격 PDF URL → 임시파일 다운로드 헬퍼 (docs/discover-feature-spec.md Track C-1).
///
/// discover 추천(PDF format)을 서재에 편입하기 전, 기기로 내려받아 기존 멀티파트 업로드
/// (`/api/pdf/upload`)에 넘긴다. 진행률은 `onProgress`(0.0~1.0, 서버가 Content-Length를 줄 때만)로
/// 콜백한다. 취소는 Task.cancel()로 전파된다.
enum PdfDownloader {
    enum DownloadError: LocalizedError {
        case badStatus(Int)
        case notPDF(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "자료를 내려받지 못했어요 (\(code))."
            case .notPDF: return "이 링크는 PDF 파일이 아니에요."
            case .empty: return "내려받은 파일이 비어 있어요."
            }
        }
    }

    /// `url`을 임시 디렉토리에 .pdf로 내려받고 로컬 파일 URL을 반환한다.
    /// 호출부는 업로드 후 `cleanup(_:)`으로 임시파일을 지운다.
    static func download(
        from url: URL,
        suggestedName: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.badStatus(0)
        }
        guard 200..<300 ~= http.statusCode else {
            throw DownloadError.badStatus(http.statusCode)
        }
        // content-type이 pdf가 아니어도 url이 .pdf면 통과(서버가 octet-stream을 줄 때 대비).
        let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksPDF = ctype.contains("pdf")
            || url.pathExtension.lowercased() == "pdf"
            || ctype.contains("octet-stream")
        if !looksPDF {
            throw DownloadError.notPDF(ctype)
        }

        let total = http.expectedContentLength  // -1 if unknown
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            received += 1
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if let onProgress, total > 0 {
                    onProgress(Double(received) / Double(total))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        if received == 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw DownloadError.empty
        }
        onProgress?(1.0)

        // 서버가 보낸 파일명을 살려서 최종 경로를 정리(서재 표시용). 실패해도 tmp 그대로 반환.
        let safeName = sanitizedFileName(suggestedName)
        let named = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: named)
        do {
            try FileManager.default.moveItem(at: tmp, to: named)
            return named
        } catch {
            return tmp
        }
    }

    static func cleanup(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "discover" }
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        name = name.components(separatedBy: invalid).joined(separator: "_")
        if !name.lowercased().hasSuffix(".pdf") {
            name += ".pdf"
        }
        // 과도하게 긴 이름 컷.
        if name.count > 120 {
            name = String(name.suffix(120))
        }
        return name
    }
}
