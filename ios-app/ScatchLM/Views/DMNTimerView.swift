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

    @Environment(\.dismiss) private var dismiss

    private enum Phase { case setup, running, done }
    @State private var phase: Phase = .setup
    @State private var totalSeconds: Int = 0
    @State private var remaining: Int = 0
    @State private var wordIndex: Int = 0
    /// 단어 슬라이드 순서(셔플) — 매번 같은 순서가 아니도록.
    @State private var shuffled: [String] = []

    /// 프리셋(분). DMN 휴식은 짧게 — 3·5·10분.
    private let presets: [Int] = [3, 5, 10]
    /// 단어 교체 간격(초).
    private let wordInterval = 5

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
        .statusBarHidden(true)
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

            Button("닫기") { dismiss() }
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

                // 가운데 단어 — 교차 페이드
                Text(currentWord)
                    .font(.system(size: 30, weight: .light, design: .serif))
                    .foregroundStyle(.white)
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
        Button { dismiss() } label: {
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
        guard !shuffled.isEmpty else { return "…" }
        return shuffled[wordIndex % shuffled.count]
    }

    private func start(minutes: Int) {
        totalSeconds = minutes * 60
        remaining = totalSeconds
        wordIndex = 0
        shuffled = words.shuffled()
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
        if elapsed % wordInterval == 0, !shuffled.isEmpty {
            withAnimation(.easeInOut(duration: 0.8)) {
                wordIndex = (wordIndex + 1) % shuffled.count
            }
        }
    }
}
