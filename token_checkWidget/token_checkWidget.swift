import WidgetKit
import SwiftUI

struct TokenWidgetEntry: TimelineEntry {
    let date: Date
    let usage: WidgetTodayUsage?
}

private func readUsageFromAppGroup() -> WidgetTodayUsage? {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
          let data = defaults.data(forKey: "today_usage") else { return nil }
    return try? JSONDecoder().decode(WidgetTodayUsage.self, from: data)
}

struct TokenTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokenWidgetEntry {
        TokenWidgetEntry(date: Date(), usage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TokenWidgetEntry) -> Void) {
        let usage = readUsageFromAppGroup()
        completion(TokenWidgetEntry(date: Date(), usage: usage))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenWidgetEntry>) -> Void) {
        let usage = readUsageFromAppGroup()
        let entry = TokenWidgetEntry(date: Date(), usage: usage)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 {
        String(format: "%.1fM", Double(n) / 1_000_000)
    } else if n >= 1_000 {
        String(format: "%.0fK", Double(n) / 1_000)
    } else {
        "\(n)"
    }
}

private func formatCost(_ c: Double) -> String {
    String(format: "¥%.2f", c)
}

struct TokenCheckWidgetEntryView: View {
    var entry: TokenTimelineProvider.Entry

    private var total7Day: Int {
        entry.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

    var body: some View {
        if let usage = entry.usage {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(.blue)
                        .font(.headline)
                    Text(formatTokens(usage.totalTokens))
                        .font(.title2.monospaced().bold())
                        .foregroundStyle(.blue)
                    Text(formatCost(usage.todayCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)

                HStack(spacing: 0) {
                    statItem("输入", formatTokens(usage.inputTokens), .blue)
                    Spacer()
                    statItem("缓存", formatTokens(usage.cacheReadTokens), .purple)
                    Spacer()
                    statItem("输出", formatTokens(usage.outputTokens), .green)
                    Spacer()
                    statItem("会话", "\(usage.sessionCount)", .orange)
                }
                .font(.caption2)
                .padding(.horizontal, 14)

                if !usage.dailyTokens.isEmpty {
                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)

                    HStack(spacing: 0) {
                        Text("近7天")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("共 \(formatTokens(total7Day))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)

                    let maxVal = max(usage.dailyTokens.map(\.totalTokens).max() ?? 1, 1)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(usage.dailyTokens.enumerated()), id: \.element.id) { _, item in
                                let ratio = CGFloat(item.totalTokens) / CGFloat(maxVal)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.blue.gradient)
                                    .frame(height: max(4, ratio * geo.size.height))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
            }
            .containerBackground(.regularMaterial, for: .widget)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
                Text("等待数据...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(.regularMaterial, for: .widget)
        }
    }

    private func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct TokenCheckWidget: Widget {
    let kind: String = "TokenCheckWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TokenTimelineProvider()) { entry in
            TokenCheckWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Token 用量")
        .description("显示今日 OpenCode Token 用量和近7天趋势。")
        .supportedFamilies([.systemMedium])
    }
}
