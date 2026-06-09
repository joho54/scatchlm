import SwiftUI

/// 앱 로고 인트로 모션 (온보딩 welcome 진입용).
///
/// 컨셉(3단계):
/// 1. 여러 노트 카드(페이지)가 흩어져 교차·중첩된 "혼돈" 상태.
/// 2. 데코 페이지들이 살아남을 로고 카드에 **45° 대각선 스택**으로 정렬 → 책(페이지 더미) 입체감.
/// 3. 정렬된 데코가 랜덤 순서로 한 장씩 미끄러져 사라지고 **로고 카드 + 펜만 남아** 앱 아이콘으로 정착.
///
/// 구현: `docs/icons/app-icon.svg`를 24-unit 좌표로 옮긴 SwiftUI `Shape`만 사용(의존성 0,
/// 어떤 크기에서도 선명). 데코는 로고 앞 카드와 동일한 페이지 모양을 offset/rotation으로 변형해
/// 흩어짐→정렬을 표현한다. 펜이 카드를 관통하는 컷은 `penCut` 마스크로 재현한다.
struct LogoIntroView: View {
    var size: CGFloat = 140
    /// 데코 소거 + 로고 정착이 끝나면 호출 (텍스트 페이드인 트리거 등).
    var onComplete: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 한 장의 페이지. 흩어짐 offset(24-unit)·회전과 정렬 슬롯(스텝 배수), 생존 여부를 가진다.
    /// 모든 페이지가 흩어짐 → 슬롯 정렬을 함께 수행하고, 데코(slot -1·2)만 정렬 후 fade out한다.
    /// 슬롯 0·1은 로고 앞/뒤 카드(생존, penCut 적용). 같은 앞-카드 모양을 슬롯만큼 어긋내 그린다.
    private struct Page { var slot: CGFloat; var dx: CGFloat; var dy: CGFloat; var rot: Double; var survivor: Bool }
    private static let pages: [Page] = [   // 뒤→앞(슬롯 내림차순)으로 그려 z-순서 = 책 적층.
        Page(slot:  2, dx:  6.5, dy: -5.5, rot: -19, survivor: false),  // 우측 상단 데코
        Page(slot:  1, dx:  4.5, dy:  6.5, rot:  21, survivor: true),   // 뒤 카드
        Page(slot:  0, dx: -6.0, dy: -3.5, rot: -12, survivor: true),   // 앞 카드
        Page(slot: -1, dx: -7.0, dy:  3.0, rot:  16, survivor: false),  // 좌측 하단 데코
    ]

    /// 45° 대각선 스택 한 칸 간격(24-unit). 로고 두 카드의 어긋남(앞 x4y5 → 뒤 x6y3 = +2,-2)과
    /// 동일. 스텝 벡터는 우상향 (+2, -2).
    private static let stackStep: CGFloat = 2.0

    @State private var fieldIn = false      // 전체 페이드/팝 인
    @State private var aligned = false      // 흩어짐 → 대각선 스택 정렬
    @State private var gone = [Bool](repeating: false, count: pages.count)   // 데코 한 장씩 소거
    @State private var penShown = false     // 데코 소거 후 마지막에 펜(+카드 컷) 등장
    @State private var didComplete = false

    // 로고 카드 기준 모양 — 모든 페이지가 이 앞-카드 모양을 공유하고 슬롯 offset으로 어긋난다.
    private let frontCard = RectSpec(x: 4, y: 5, w: 14, h: 16, rot: 0)

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.376, green: 0.647, blue: 0.980),    // #60a5fa
                     Color(red: 0.145, green: 0.388, blue: 0.922)],   // #2563eb
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var lineWidth: CGFloat { size / 24 }   // svg stroke-width 1

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            gradient

            // 모든 페이지(데코+로고) — 흩어짐 → 45° 대각선 슬롯 정렬.
            // 생존 페이지(슬롯 0·1)는 penCut 마스크로 펜과 분리, 데코는 정렬 후 fade out.
            ForEach(Self.pages.indices, id: \.self) { i in
                pageView(i)
            }

            Pen24().stroke(.white, style: strokeStyle)
                .opacity(penShown ? 1 : 0)
                .scaleEffect(penShown ? 1 : 0.86)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .scaleEffect(fieldIn ? 1 : 0.92)
        .opacity(fieldIn ? 1 : 0)
        .onAppear(perform: play)
    }

    /// app-icon.svg의 `mask#penCut` 재현 — 흰 바탕에 펜 모양(채움 + 2-stroke)을 검게 찍어
    /// 카드 스트로크에 펜 모양 구멍을 뚫는다. luminanceToAlpha로 흰=불투명/검=투명 변환.
    private var penCutMask: some View {
        ZStack {
            Rectangle().fill(.white)
            // 펜이 떠야 비로소 카드에 구멍이 뚫린다(penShown 전엔 카드가 온전).
            Pen24().fill(.black).opacity(penShown ? 1 : 0)
            Pen24().stroke(.black, lineWidth: lineWidth * 2).opacity(penShown ? 1 : 0)
        }
        .compositingGroup()
        .luminanceToAlpha()
    }

    // MARK: 페이지 변형 (흩어짐 / 대각선 슬롯 정렬 / 데코 소거)

    private var unit: CGFloat { size / 24 }

    /// 한 페이지 뷰. 생존 페이지는 penCut 마스크(펜과 분리), 데코는 정렬 후 fade out.
    @ViewBuilder
    private func pageView(_ i: Int) -> some View {
        let p = Self.pages[i]
        let card = Rect24(spec: frontCard)
            .stroke(.white.opacity(p.survivor ? 1 : 0.92), style: strokeStyle)
            .rotationEffect(.degrees((aligned || gone[i]) ? 0 : p.rot))
            .offset(pageOffset(i))
        if p.survivor {
            // 마스크는 프레임 좌표 고정 — 정렬 후 카드가 제자리에 오면 펜 컷이 정확히 맞는다.
            card.compositingGroup().mask(penCutMask)
        } else {
            card.opacity(gone[i] ? 0 : 1)
        }
    }

    /// 흩어짐 offset → 정렬 시 슬롯(±대각선) 위치. 데코 소거는 위치 이동 없이 제자리 fade out.
    /// 스텝 벡터는 우상향 (+1, -1). 슬롯 음수=좌측 하단, 양수=우측 상단.
    private func pageOffset(_ i: Int) -> CGSize {
        let p = Self.pages[i]
        if aligned {
            let step = Self.stackStep * unit
            return CGSize(width: p.slot * step, height: -p.slot * step)
        }
        return CGSize(width: p.dx * unit, height: p.dy * unit)
    }

    private func play() {
        guard !reduceMotion else {
            // 모션 최소화: 데코 없이 최종 로고(펜 포함)만 즉시 표시.
            gone = Self.pages.map { !$0.survivor }
            aligned = true
            penShown = true
            fieldIn = true
            complete()
            return
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { fieldIn = true }

        // 1) 모든 페이지가 흩어짐 → 45° 대각선 스택으로 정렬 (책 입체감).
        withAnimation(.spring(response: 0.55, dampingFraction: 0.74).delay(0.25)) { aligned = true }
        let alignDone = 0.25 + 0.6

        // 2) 정렬된 스택의 데코를 랜덤 순서로 한 장씩 fade out → 로고만 남는다.
        let order = Self.pages.indices.filter { !Self.pages[$0].survivor }.shuffled()
        let step = 0.13
        let removeStart = alignDone + 0.45      // 스택을 잠깐 보여준 뒤 소거 시작
        for (k, idx) in order.enumerated() {
            withAnimation(.easeIn(duration: 0.4).delay(removeStart + Double(k) * step)) {
                gone[idx] = true
            }
        }
        // 3) 데코가 다 사라진 뒤 마지막에 펜(+카드 컷)이 떠 로고 완성.
        let penAt = removeStart + Double(order.count) * step + 0.35
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(penAt)) { penShown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + penAt + 0.5) { complete() }
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        onComplete?()
    }
}

// MARK: - 24-unit 좌표 Shape (app-icon.svg viewBox 0 0 24 24)

/// 카드 사각형 명세. 좌표/크기는 svg 24-unit 기준.
private struct RectSpec {
    var x: CGFloat, y: CGFloat
    var w: CGFloat = 14, h: CGFloat = 16
    var corner: CGFloat = 2
    var rot: Double = 0
}

private struct Rect24: Shape {
    let spec: RectSpec
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        let r = CGRect(x: spec.x * s, y: spec.y * s, width: spec.w * s, height: spec.h * s)
        return Path(roundedRect: r, cornerRadius: spec.corner * s)
    }
}

/// 펜 path: `M21.5 18.5 a1.5 1.5 0 0 1 -2 2 L12 13 L11 10 L14 11 Z`
/// 둥근 꼭지(arc)는 동일 스케일에서 시각적으로 같은 quad curve로 근사.
private struct Pen24: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func P(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: a * s, y: b * s) }
        var p = Path()
        p.move(to: P(21.5, 18.5))
        p.addQuadCurve(to: P(19.5, 20.5), control: P(21.5, 20.5))
        p.addLine(to: P(12, 13))
        p.addLine(to: P(11, 10))
        p.addLine(to: P(14, 11))
        p.closeSubpath()
        return p
    }
}

#Preview("Logo intro") {
    // 캔버스에서 탭하면 모션 재생. id 변경으로 뷰를 재생성해 리플레이.
    struct Replay: View {
        @State private var n = 0
        var body: some View {
            VStack(spacing: 24) {
                LogoIntroView(size: 200).id(n)
                Button("다시 재생") { n += 1 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }
    return Replay()
}
