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

// MARK: - 小尺寸热力图小组件

struct HeatmapWidgetEntry: TimelineEntry {
    let date: Date
    let data: WidgetMonthlyHeatmapData?
}

private func readHeatmapFromAppGroup() -> WidgetMonthlyHeatmapData? {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
          let data = defaults.data(forKey: "monthly_heatmap") else { return nil }
    return try? JSONDecoder().decode(WidgetMonthlyHeatmapData.self, from: data)
}

struct HeatmapTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeatmapWidgetEntry {
        HeatmapWidgetEntry(date: Date(), data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (HeatmapWidgetEntry) -> Void) {
        let data = readHeatmapFromAppGroup()
        completion(HeatmapWidgetEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeatmapWidgetEntry>) -> Void) {
        let data = readHeatmapFromAppGroup()
        let entry = HeatmapWidgetEntry(date: Date(), data: data)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

extension Color {
    static let heatmapEmpty = Color(.sRGB, red: 0.85, green: 0.85, blue: 0.87, opacity: 0.25)
    static let heatmap1 = Color.blue.opacity(0.2)
    static let heatmap2 = Color.blue.opacity(0.4)
    static let heatmap3 = Color.blue.opacity(0.6)
    static let heatmap4 = Color.blue.opacity(0.85)
}

struct MonthHeatmapEntryView: View {
    var entry: HeatmapWidgetEntry

    private let cellSize: CGFloat = 14
    private let spacing: CGFloat = 2
    private let dayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        if let data = entry.data {
            VStack(spacing: 0) {
                headerView(data: data)
                Spacer(minLength: 6)
                heatmapGrid(data: data)
                Spacer(minLength: 4)
                footerView(data: data)
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

    private func headerView(data: WidgetMonthlyHeatmapData) -> some View {
        HStack {
            Text("\(data.month)月")
                .font(.headline)
                .foregroundStyle(.blue)
            Spacer()
            Text(formatTokens(data.totalTokens))
                .font(.caption.monospaced().bold())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func heatmapGrid(data: WidgetMonthlyHeatmapData) -> some View {
        let offset = (data.firstWeekday + 5) % 7
        let totalDays = data.days.count
        let numWeeks = (offset + totalDays + 6) / 7
        let thresholds = computeThresholds(data: data)

        return HStack(spacing: spacing) {
            VStack(spacing: spacing) {
                ForEach(dayLabels.indices, id: \.self) { i in
                    Text(dayLabels[i])
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(height: cellSize)
                }
            }
            .frame(width: 10)

            ForEach(0..<numWeeks, id: \.self) { week in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let dayIndex = week * 7 + weekday - offset
                        let cellColor: Color = {
                            guard dayIndex >= 0 && dayIndex < totalDays else {
                                return .clear
                            }
                            let tokens = data.days[dayIndex].totalTokens
                            return colorForTokens(tokens, thresholds: thresholds)
                        }()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cellColor)
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func footerView(data: WidgetMonthlyHeatmapData) -> some View {
        HStack {
            Spacer()
            Text("日均 \(formatTokens(data.avgDailyTokens))")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func computeThresholds(data: WidgetMonthlyHeatmapData) -> [Int] {
        let nonZero = data.days.map(\.totalTokens).filter { $0 > 0 }.sorted()
        guard nonZero.count >= 4 else {
            return [100, 1000, 10000, 100000]
        }
        let count = nonZero.count
        return [
            nonZero[count * 1 / 4],
            nonZero[count * 2 / 4],
            nonZero[count * 3 / 4],
            nonZero[count - 1]
        ]
    }

    private func colorForTokens(_ tokens: Int, thresholds: [Int]) -> Color {
        guard tokens > 0 else { return .heatmapEmpty }
        if tokens <= thresholds[0] { return .heatmap1 }
        if tokens <= thresholds[1] { return .heatmap2 }
        if tokens <= thresholds[2] { return .heatmap3 }
        return .heatmap4
    }
}

struct TokenCheckSmallWidget: Widget {
    let kind: String = "TokenCheckSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HeatmapTimelineProvider()) { entry in
            MonthHeatmapEntryView(entry: entry)
        }
        .configurationDisplayName("Token 热力图")
        .description("显示当月 Token 用量热力图。")
        .supportedFamilies([.systemSmall])
    }
}
