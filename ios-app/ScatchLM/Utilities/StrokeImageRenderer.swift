import UIKit
import PencilKit

/// 스트로크 → 피드백 전송용 이미지(JPEG) 렌더 (가이드된 첫 성공 spec §4.4 / B-2).
///
/// `NoteView.requestFeedback`의 순수 렌더 부분을 추출해 노트·온보딩이 공유한다.
/// 흰 배경 + 가시 잉크, 다크모드면 잉크 색 반전, 교정용 템플릿은 배경 선을 함께 합성.
/// **반드시 메인 스레드에서 호출**한다 — `PKDrawing.image()`의 off-main 호출은 프로세스 전역
/// 필기 렌더를 손상시킨다(memory: pencilkit_offmain_render).
enum StrokeImageRenderer {
    struct Result {
        let jpeg: Data
        let bounds: CGRect
        let imageSize: CGSize
    }

    /// - Returns: 렌더 결과. 스트로크가 비었거나(빈 bounds) 인코딩 실패 시 nil.
    @MainActor
    static func render(
        strokes: [PKStroke],
        template: NoteTemplate,
        isDark: Bool,
        maxDim: CGFloat = 2000,
        compressionQuality: CGFloat = 0.8
    ) -> Result? {
        let newDrawing = PKDrawing(strokes: strokes)
        let bounds = newDrawing.bounds
        guard !bounds.isEmpty else { return nil }

        // 캡처 — 항상 흰 배경 + 가시적 잉크. 최대 maxDim로 리사이즈(API 속도/비용).
        let rawImage = newDrawing.image(from: bounds, scale: 1.0)
        let imgSize = rawImage.size
        let ratio = max(imgSize.width, imgSize.height) > maxDim
            ? maxDim / max(imgSize.width, imgSize.height)
            : 1.0
        let targetSize = CGSize(width: imgSize.width * ratio, height: imgSize.height * ratio)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let finalImage = renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))

            // 교정용 템플릿(오선지·영어 4선·원고지)은 배경 선을 컨텍스트로 함께 보낸다.
            // 정리용(줄노트·격자·도트·코넬)은 OCR 노이즈라 잉크만 — includesLinesInFeedback로 분기.
            if template.includesLinesInFeedback, ratio > 0 {
                cg.saveGState()
                cg.scaleBy(x: ratio, y: ratio)
                cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                CanvasTemplateLayer.render(
                    template: template, isDark: false,
                    contentWidth: Config.logicalCanvasWidth, rect: bounds,
                    alphaOverride: 0.45,
                    lineWidthOverride: max(0.75, 1.2 / ratio),
                    in: cg)
                cg.restoreGState()
            }

            if isDark {
                guard let cgImage = rawImage.cgImage,
                      let ciImage = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: CIImage(cgImage: cgImage)])?.outputImage,
                      let invertedCG = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
                    rawImage.draw(in: CGRect(origin: .zero, size: targetSize))
                    return
                }
                UIImage(cgImage: invertedCG).draw(in: CGRect(origin: .zero, size: targetSize))
            } else {
                rawImage.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }

        guard let jpeg = finalImage.jpegData(compressionQuality: compressionQuality) else { return nil }
        return Result(jpeg: jpeg, bounds: bounds, imageSize: finalImage.size)
    }
}
