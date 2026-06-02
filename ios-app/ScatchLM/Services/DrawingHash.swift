import Foundation
import CryptoKit

/// PKDrawing 등 blob의 content-addressed 해시 유틸 (§4.4, C-4).
/// drawing_hash = sha256(dataRepresentation)의 hex 문자열. 빈 데이터는 nil(빈 드로잉).
enum DrawingHash {
    /// 데이터의 sha256 hex. nil 또는 빈 데이터면 nil(=빈 드로잉, drawing_hash 없음).
    static func hash(for data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return sha256(data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
