import CoreImage
import UIKit

/// Generates a specular highlight map for glass edge reflection.
class SpecularGenerator {

    /// Generate specular highlight as CIImage
    /// Bright pixels along the edge where the light "catches" the glass rim
    static func generate(
        width: Int, height: Int,
        radius: CGFloat,
        bezelWidth: CGFloat,
        specularAngle: CGFloat = .pi / 3
    ) -> CIImage? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let specularVector = (x: cos(specularAngle), y: sin(specularAngle))
        let thickness: CGFloat = 1.5

        let objW = CGFloat(width)
        let objH = CGFloat(height)
        let r = radius
        let rSq = r * r
        let rPlusSq = (r + 1) * (r + 1)
        let rMinusTSq = max(0, (r - thickness) * (r - thickness))
        let wBetween = objW - r * 2
        let hBetween = objH - r * 2

        for y1 in 0..<height {
            for x1 in 0..<width {
                let idx = (y1 * width + x1) * 4

                let isL = CGFloat(x1) < r
                let isR = CGFloat(x1) >= objW - r
                let isT = CGFloat(y1) < r
                let isB = CGFloat(y1) >= objH - r

                let x: CGFloat = isL ? CGFloat(x1) - r : isR ? CGFloat(x1) - r - wBetween : 0
                let y: CGFloat = isT ? CGFloat(y1) - r : isB ? CGFloat(y1) - r - hBetween : 0

                let dSq = x * x + y * y

                guard dSq <= rPlusSq && dSq >= rMinusTSq else { continue }

                let dist = sqrt(dSq)
                let distFromSide = r - dist
                let opacity: CGFloat = dSq < rSq ? 1.0 :
                    1.0 - (dist - sqrt(rSq)) / (sqrt(rPlusSq) - sqrt(rSq))

                let cosA = dist > 0 ? x / dist : 0
                let sinA = dist > 0 ? -y / dist : 0

                let dotProduct = abs(cosA * specularVector.x + sinA * specularVector.y)
                let edgeRatio = max(0, min(1, distFromSide / thickness))
                let sharpFalloff = sqrt(1.0 - (1.0 - edgeRatio) * (1.0 - edgeRatio))
                let coefficient = dotProduct * sharpFalloff

                let color = UInt8(clamping: Int(255.0 * coefficient))
                let alpha = UInt8(clamping: Int(255.0 * coefficient * coefficient * opacity))

                pixelData[idx] = color
                pixelData[idx + 1] = color
                pixelData[idx + 2] = color
                pixelData[idx + 3] = alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        return CIImage(cgImage: cgImage)
    }
}
