import UIKit

/// 캔버스 배경 템플릿(줄노트/격자/오선지)을 그리는 타일 레이어.
///
/// 캔버스는 높이가 무한 확장되고(`Coordinator.setContentHeight`) 1x~3x로 핀치 줌된다.
/// 전체 contentView를 한 비트맵으로 래스터화하면 (1) 키 큰 페이지에서 메모리가 폭증하고
/// (2) 줌하면 비트맵이 확대돼 선이 뭉개진다. `CATiledLayer`는 보이는 타일만 "현재 렌더 스케일로"
/// 다시 벡터 렌더하므로 메모리는 타일 단위로 한정되고 어느 줌에서도 선이 선명하다.
///
/// CATiledLayer 기본 fade-in 애니메이션은 타일 등장 시 깜빡임을 유발하므로 0으로 끈다
/// (이 코드베이스의 고질적 민감 지점). frame 변경(높이 확장) 시에도 implicit 애니메이션을
/// 호출부(setContentHeight)에서 CATransaction으로 차단한다.
final class CanvasTemplateLayer: CATiledLayer {
    var template: NoteTemplate = .blank {
        didSet { if template != oldValue { setNeedsDisplay() } }
    }
    /// 다크모드면 흰 선, 라이트면 검은 선(낮은 농도).
    var isDark: Bool = false {
        didSet { if isDark != oldValue { setNeedsDisplay() } }
    }

    /// 타일 fade-in 제거 — 깜빡임 방지.
    override class func fadeDuration() -> CFTimeInterval { 0 }

    override func draw(in ctx: CGContext) {
        guard template != .blank else { return }
        // 이 호출에서 그릴 타일 영역. 타일 밖은 CA가 clip하지만, 라인 개수를 줄이려 직접 범위를 좁힌다.
        let tile = ctx.boundingBoxOfClipPath
        guard tile.width > 0, tile.height > 0 else { return }

        let m = template.metrics
        let inkColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(m.opacity)
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setFillColor(inkColor.cgColor)
        ctx.setLineWidth(m.lineWidth)

        // 각 case는 자기 stroke/fill을 자체적으로 마감한다(점선·점 렌더가 섞여 공통 strokePath 불가).
        switch template {
        case .blank:
            break
        case .lined:
            drawHorizontals(in: ctx, tile: tile, spacing: m.rowHeight)
            ctx.strokePath()
        case .grid:
            drawHorizontals(in: ctx, tile: tile, spacing: m.rowHeight)
            drawVerticals(in: ctx, tile: tile, spacing: m.rowHeight)
            ctx.strokePath()
        case .manuscript:
            // 글자 한 칸씩 — 정사각 칸 격자.
            drawHorizontals(in: ctx, tile: tile, spacing: m.rowHeight)
            drawVerticals(in: ctx, tile: tile, spacing: m.rowHeight)
            ctx.strokePath()
        case .dotgrid:
            drawDots(in: ctx, tile: tile, spacing: m.rowHeight, radius: m.dotRadius)
        case .fourline:
            drawFourLine(in: ctx, tile: tile, metrics: m)
        case .staff:
            drawStaves(in: ctx, tile: tile, metrics: m)
            ctx.strokePath()
        case .cornell:
            drawHorizontals(in: ctx, tile: tile, spacing: m.rowHeight)
            drawCornellCue(in: ctx, tile: tile, fraction: m.cueFraction)
            ctx.strokePath()
        }
    }

    /// y = k*spacing 인 수평선 중 타일에 걸치는 것만.
    private func drawHorizontals(in ctx: CGContext, tile: CGRect, spacing: CGFloat) {
        guard spacing > 0 else { return }
        var y = (tile.minY / spacing).rounded(.up) * spacing
        while y <= tile.maxY {
            ctx.move(to: CGPoint(x: tile.minX, y: y))
            ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
            y += spacing
        }
    }

    /// x = j*spacing 인 수직선 중 타일에 걸치는 것만.
    private func drawVerticals(in ctx: CGContext, tile: CGRect, spacing: CGFloat) {
        guard spacing > 0 else { return }
        var x = (tile.minX / spacing).rounded(.up) * spacing
        while x <= tile.maxX {
            ctx.move(to: CGPoint(x: x, y: tile.minY))
            ctx.addLine(to: CGPoint(x: x, y: tile.maxY))
            x += spacing
        }
    }

    /// 도트 그리드: (j*spacing, k*spacing) 교점에 작은 점. tile에 걸치는 점만 fill.
    private func drawDots(in ctx: CGContext, tile: CGRect, spacing: CGFloat, radius: CGFloat) {
        guard spacing > 0, radius > 0 else { return }
        var y = (tile.minY / spacing).rounded(.up) * spacing
        while y <= tile.maxY {
            var x = (tile.minX / spacing).rounded(.up) * spacing
            while x <= tile.maxX {
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
    }

    /// 영어 4선: 4줄 묶음. 위→아래 L0(상단)·L1(x-height, 점선)·L2(베이스라인)·L3(하단).
    /// 묶음 pitch = 3*staffGap(묶음 높이) + groupGap.
    private func drawFourLine(in ctx: CGContext, tile: CGRect, metrics m: NoteTemplate.Metrics) {
        let groupHeight = m.staffGap * 3
        let pitch = groupHeight + m.groupGap
        guard pitch > 0 else { return }
        let topMargin = m.groupGap
        let firstG = Int(((tile.minY - topMargin - groupHeight) / pitch).rounded(.down))
        let lastG = Int(((tile.maxY - topMargin) / pitch).rounded(.up))
        let lo = max(0, firstG)
        let hi = max(lo, lastG)

        // 실선(L0/L2/L3)
        for g in lo...hi {
            let top = topMargin + CGFloat(g) * pitch
            for i in [0, 2, 3] {
                let y = top + CGFloat(i) * m.staffGap
                if y < tile.minY - 1 || y > tile.maxY + 1 { continue }
                ctx.move(to: CGPoint(x: tile.minX, y: y))
                ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
            }
        }
        ctx.strokePath()

        // 점선(L1 = x-height 가이드)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        for g in lo...hi {
            let y = topMargin + CGFloat(g) * pitch + m.staffGap
            if y < tile.minY - 1 || y > tile.maxY + 1 { continue }
            ctx.move(to: CGPoint(x: tile.minX, y: y))
            ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])   // 리셋
    }

    /// 코넬 단서칸 세로 구분선 — 논리폭 대비 fraction 위치에 전체 높이 1줄.
    private func drawCornellCue(in ctx: CGContext, tile: CGRect, fraction: CGFloat) {
        guard fraction > 0 else { return }
        let cueX = bounds.width * fraction
        guard cueX >= tile.minX, cueX <= tile.maxX else { return }
        ctx.move(to: CGPoint(x: cueX, y: tile.minY))
        ctx.addLine(to: CGPoint(x: cueX, y: tile.maxY))
        // strokePath는 호출부(case .cornell)에서 horizontals와 함께 일괄.
    }

    /// 오선: 5줄 묶음이 staffGap 간격으로 붙고, 묶음 사이(및 상단)는 groupGap.
    /// 묶음 pitch = 4*staffGap(묶음 높이) + groupGap. 타일에 걸치는 묶음만 그린다.
    private func drawStaves(in ctx: CGContext, tile: CGRect, metrics m: NoteTemplate.Metrics) {
        let staffHeight = m.staffGap * 4
        let pitch = staffHeight + m.groupGap
        guard pitch > 0 else { return }
        let topMargin = m.groupGap   // 첫 오선 묶음 위 여백

        let firstG = Int(((tile.minY - topMargin - staffHeight) / pitch).rounded(.down))
        let lastG = Int(((tile.maxY - topMargin) / pitch).rounded(.up))
        let lo = max(0, firstG)
        let hi = max(lo, lastG)
        for g in lo...hi {
            let top = topMargin + CGFloat(g) * pitch
            for i in 0..<5 {
                let y = top + CGFloat(i) * m.staffGap
                if y < tile.minY - 1 || y > tile.maxY + 1 { continue }
                ctx.move(to: CGPoint(x: tile.minX, y: y))
                ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
            }
        }
    }
}
