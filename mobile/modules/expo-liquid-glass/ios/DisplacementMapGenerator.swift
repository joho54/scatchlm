import CoreImage
import UIKit

/// Generates a displacement map using Snell's Law for realistic glass edge refraction.
/// Ported from the HTML liquid-glass-demo (kube.io approach).
class DisplacementMapGenerator {

    /// Convex squircle surface profile: y = (1 - (1-x)^4)^(1/4)
    private static func surfaceHeight(_ x: CGFloat) -> CGFloat {
        return pow(1.0 - pow(1.0 - x, 4), 0.25)
    }

    /// Snell's law refraction for a ray hitting a surface
    private static func refract(normalX: CGFloat, normalY: CGFloat, eta: CGFloat) -> (x: CGFloat, y: CGFloat)? {
        let dot = normalY
        let k = 1.0 - eta * eta * (1.0 - dot * dot)
        guard k >= 0 else { return nil }
        let kSqrt = sqrt(k)
        return (
            x: -(eta * dot + kSqrt) * normalX,
            y: eta - (eta * dot + kSqrt) * normalY
        )
    }

    /// 1D displacement along a single radius using Snell's Law
    private static func precompute1D(
        glassThickness: CGFloat,
        bezelWidth: CGFloat,
        refractiveIndex: CGFloat,
        samples: Int = 128
    ) -> [CGFloat] {
        let eta = 1.0 / refractiveIndex
        var result: [CGFloat] = []
        result.reserveCapacity(samples)

        for i in 0..<samples {
            let x = CGFloat(i) / CGFloat(samples)
            let y = surfaceHeight(x)

            // Numerical derivative
            let dx: CGFloat = x < 1.0 ? 0.0001 : -0.0001
            let x2 = max(0, min(1, x + dx))
            let y2 = surfaceHeight(x2)
            let derivative = (y2 - y) / dx

            // Surface normal
            let magnitude = sqrt(derivative * derivative + 1.0)
            let nx = -derivative / magnitude
            let ny: CGFloat = -1.0 / magnitude

            guard let refracted = refract(normalX: nx, normalY: ny, eta: eta) else {
                result.append(0)
                continue
            }

            let remainingHeight = y * bezelWidth + glassThickness
            let displacement = refracted.x * (remainingHeight / refracted.y)
            result.append(displacement)
        }

        return result
    }

    /// Generate a 2D displacement map as CIImage
    /// R channel = X displacement, G channel = Y displacement
    /// Neutral (no displacement) = 128
    static func generate(
        width: Int, height: Int,
        radius: CGFloat,
        bezelWidth: CGFloat,
        glassThickness: CGFloat,
        refractiveIndex: CGFloat
    ) -> CIImage? {
        let precomputed = precompute1D(
            glassThickness: glassThickness,
            bezelWidth: bezelWidth,
            refractiveIndex: refractiveIndex
        )

        let maxDisplacement = precomputed.map { abs($0) }.max() ?? 1.0

        // Create bitmap
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        // Fill with neutral (128, 128, 0, 255)
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            pixelData[i] = 128     // R
            pixelData[i + 1] = 128 // G
            pixelData[i + 2] = 0   // B
            pixelData[i + 3] = 255 // A
        }

        let objW = CGFloat(width)
        let objH = CGFloat(height)
        let r = radius
        let rSq = r * r
        let rPlusSq = (r + 1) * (r + 1)
        let rMinusBSq = max(0, (r - bezelWidth) * (r - bezelWidth))
        let wBetween = objW - r * 2
        let hBetween = objH - r * 2

        for y1 in 0..<height {
            for x1 in 0..<width {
                let idx = (y1 * width + x1) * 4

                // Determine distance from nearest corner/edge
                let isL = CGFloat(x1) < r
                let isR = CGFloat(x1) >= objW - r
                let isT = CGFloat(y1) < r
                let isB = CGFloat(y1) >= objH - r

                let x: CGFloat = isL ? CGFloat(x1) - r : isR ? CGFloat(x1) - r - wBetween : 0
                let y: CGFloat = isT ? CGFloat(y1) - r : isB ? CGFloat(y1) - r - hBetween : 0

                let dSq = x * x + y * y

                guard dSq <= rPlusSq && dSq >= rMinusBSq else { continue }

                let dist = sqrt(dSq)
                let opacity: CGFloat = dSq < rSq ? 1.0 :
                    1.0 - (dist - sqrt(rSq)) / (sqrt(rPlusSq) - sqrt(rSq))

                let cosA = dist > 0 ? x / dist : 0
                let sinA = dist > 0 ? y / dist : 0

                let distFromSide = r - dist
                let bezelRatio = max(0, min(1, distFromSide / bezelWidth))
                let bezelIdx = min(Int(bezelRatio * CGFloat(precomputed.count)), precomputed.count - 1)
                let displacement = precomputed[max(0, bezelIdx)]

                let dX = maxDisplacement > 0 ? (-cosA * displacement) / maxDisplacement : 0
                let dY = maxDisplacement > 0 ? (-sinA * displacement) / maxDisplacement : 0

                pixelData[idx] = UInt8(clamping: Int(128 + dX * 127 * opacity))
                pixelData[idx + 1] = UInt8(clamping: Int(128 + dY * 127 * opacity))
            }
        }

        // Create CGImage from pixel data
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
