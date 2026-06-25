import WidgetKit
import SwiftUI

/// 최근 공부한 인출 단서(키워드)를 홈/잠금화면에 띄우는 위젯.
///
/// 데이터는 앱이 App Group 공유 저장소에 써둔 `WidgetCue` 스냅샷(읽기 전용). 단서를 탭하면
/// 딥링크(`scatchlm://session/<id>`)로 해당 세션 대화 시트가 열린다.

struct CueEntry: TimelineEntry {
    let date: Date
    let cues: [WidgetCue]
}

struct RecentStudyProvider: TimelineProvider {
    func placeholder(in context: Context) -> CueEntry {
        CueEntry(date: Date(), cues: CueEntry.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (CueEntry) -> Void) {
        let cues = context.isPreview ? CueEntry.sample : WidgetShared.readCues()
        completion(CueEntry(date: Date(), cues: cues))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CueEntry>) -> Void) {
        // 앱이 단서를 적재할 때 WidgetCenter.reloadAllTimelines()로 갱신하므로 .never로 둔다.
        let entry = CueEntry(date: Date(), cues: WidgetShared.readCues())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

extension CueEntry {
    static let sample: [WidgetCue] = [
        WidgetCue(id: "1", keyword: "경사하강", sessionId: "s1", noteId: "n1", createdAt: Date()),
        WidgetCue(id: "2", keyword: "역전파", sessionId: "s2", noteId: "n1", createdAt: Date()),
        WidgetCue(id: "3", keyword: "베이즈정리", sessionId: "s3", noteId: "n2", createdAt: Date()),
        WidgetCue(id: "4", keyword: "최적화", sessionId: "s4", noteId: "n2", createdAt: Date()),
    ]
}

struct RecentStudyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CueEntry

    private var maxCount: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 6
        default: return 10
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("최근 공부한 내용", systemImage: "brain.head.profile")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if entry.cues.isEmpty {
                Spacer()
                Text("아직 공부 기록이 없어요.")
                    .font(.footnote).foregroundStyle(.tertiary)
                Spacer()
            } else {
                content
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        let cues = Array(entry.cues.prefix(maxCount))
        if family == .systemSmall {
            // small은 위젯 전체가 한 탭 타깃 — 대표(최신) 단서로만 점프, 나머지는 나열.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(cues) { cue in
                    Text("· \(cue.keyword)")
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            .widgetURL(cues.first.flatMap { WidgetShared.deepLink(for: $0) })
        } else {
            // medium/large는 키워드마다 개별 Link → 각자 해당 세션으로 점프.
            FlowLayout(spacing: 6) {
                ForEach(cues) { cue in
                    if let url = WidgetShared.deepLink(for: cue) {
                        Link(destination: url) { chip(cue.keyword) }
                    } else {
                        chip(cue.keyword)
                    }
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

/// 칩을 줄바꿈 배치하는 간단한 flow 레이아웃(위젯엔 외부 의존성 없이 자체 구현).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct RecentStudyWidget: Widget {
    let kind = "RecentStudyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentStudyProvider()) { entry in
            RecentStudyWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("최근 공부한 내용")
        .description("최근 공부한 핵심 단서를 보여주고, 탭하면 그 대화로 이동해요.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ScatchLMWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentStudyWidget()
    }
}
