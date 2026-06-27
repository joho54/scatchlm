import SwiftUI

/// DMN(Default Mode Network) 휴식 타이머.
///
/// 공부 중 잠깐 멈추고 머릿속을 정리하는 시간을 위한 극단적으로 단순한 화면.
/// 검은 배경 위 원형 카운트다운, 가운데에 최근 피드백에서 뽑은 핵심 단어를 5초 간격으로
/// 교차 페이드. 공부는 본질적으로 정보 과잉이라 휴식 화면은 정보를 최소화해 장기기억 강화를
/// 유도(역행간섭 방지)하는 것이 목적이다.
///
/// 종료는 **명시적 버튼으로만** — tap-to-dismiss/배경 탭 종료 금지(우발 종료로 휴식이 깨지는 것 방지).
struct DMNTimerView: View {
    /// 가운데 슬라이드 오버할 단어들. 비어 있으면 차분한 안내 문구로 대체.
    let words: [String]

    /// 닫힐 때 호출. `didRest`=실제로 휴식에 들어갔는지(running/done 도달). setup에서 바로 닫으면 false.
    /// 호스트(NoteView)가 true일 때만 복귀 연출(페이지 흐림→선명)을 트리거한다 — 페이오프는 *복귀*에 있다.
    var onEnd: (_ didRest: Bool) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    private enum Phase { case setup, running, done }
    @State private var phase: Phase = .setup
    @State private var totalSeconds: Int = 0
    @State private var remaining: Int = 0
    @State private var wordIndex: Int = 0
    /// 표시할 단서 — 최신 피드백 개념이 앞. 셔플하지 않는다(주변 단서는 차분한 게 목적).
    @State private var cues: [String] = []

    /// 프리셋(분). DMN 휴식은 짧게 — 3·5·10분.
    private let presets: [Int] = [3, 5, 10]
    /// 단서 교체 간격(초). 주변 단서형 — 화면이 거의 안 변해야 초점주의를 안 끈다.
    private let wordInterval = 25

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch phase {
            case .setup:   setupView
            case .running: runningView
            case .done:    doneView
            }
        }
        // NOTE: 상태바를 숨기지 않는다. fullScreenCover로 .statusBarHidden(true)를 걸면
        // 윈도우 단위로 상태바가 사라져 뒤의 NoteView top safe-area inset이 32→0으로 붕괴했다가
        // dismiss 때 0→32로 튀어, 종료 순간 상단 UI가 위로 밀리는 글리치가 났다(원인: 로그로 확정).
        .onReceive(tick) { _ in onTick() }
        // 휴식 중 화면 잠들면 타이머가 무의미 — 켜둔다. 닫힐 때 원복.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - Setup (프리셋 선택)

    private var setupView: some View {
        VStack(spacing: 48) {
            VStack(spacing: 10) {
                Text("쉬는 시간")
                    .font(.system(size: 28, weight: .light, design: .serif))
                    .foregroundStyle(.white)
                Text("잠깐 멈추고 떠오르는 것을 따라가 보세요")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }

            HStack(spacing: 16) {
                ForEach(presets, id: \.self) { minutes in
                    Button { start(minutes: minutes) } label: {
                        VStack(spacing: 4) {
                            Text("\(minutes)")
                                .font(.system(size: 30, weight: .light))
                            Text("분")
                                .font(.system(size: 13, weight: .regular))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(
                            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                    }
                }
            }

            Button("닫기") { onEnd(false); dismiss() }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Running (카운트다운 + 단어)

    private var runningView: some View {
        VStack {
            Spacer()

            ZStack {
                // 진행 트랙
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 3)
                // 남은 시간 진행 링
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white.opacity(0.6),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)

                // 가운데 단서 — 저대비, 느린 교차 페이드(주변 단서형: 읽게 만들지 않는다)
                Text(currentWord)
                    .font(.system(size: 26, weight: .light, design: .serif))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .minimumScaleFactor(0.5)
                    .id(currentWord)
                    .transition(.opacity)
            }
            .frame(width: 300, height: 300)

            Spacer()

            Text(timeString)
                .font(.system(size: 16, weight: .light).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 24)

            endButton
                .padding(.bottom, 40)
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 40) {
            VStack(spacing: 10) {
                Text("휴식 완료")
                    .font(.system(size: 26, weight: .light, design: .serif))
                    .foregroundStyle(.white)
                Text("다시 집중할 준비가 되었어요")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
            endButton
        }
    }

    private var endButton: some View {
        // running/done에서만 노출 → 휴식에 실제로 들어간 상태. 복귀 연출 트리거(didRest=true).
        Button { onEnd(true); dismiss() } label: {
            Text("종료")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 160, height: 48)
                .background(
                    Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
        }
    }

    // MARK: - 로직

    private var progress: CGFloat {
        guard totalSeconds > 0 else { return 0 }
        return CGFloat(remaining) / CGFloat(totalSeconds)
    }

    private var timeString: String {
        let m = remaining / 60, s = remaining % 60
        return String(format: "%d:%02d", m, s)
    }

    private var currentWord: String {
        guard !cues.isEmpty else { return "" }
        return cues[wordIndex % cues.count]
    }

    private func start(minutes: Int) {
        totalSeconds = minutes * 60
        remaining = totalSeconds
        wordIndex = 0
        cues = words
        phase = .running
    }

    private func onTick() {
        guard phase == .running else { return }
        if remaining <= 1 {
            remaining = 0
            withAnimation(.easeInOut(duration: 0.6)) { phase = .done }
            return
        }
        remaining -= 1
        let elapsed = totalSeconds - remaining
        if elapsed % wordInterval == 0, !cues.isEmpty {
            withAnimation(.easeInOut(duration: 1.5)) {
                wordIndex = (wordIndex + 1) % cues.count
            }
        }
    }
}
