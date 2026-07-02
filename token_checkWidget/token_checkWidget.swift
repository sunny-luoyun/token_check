import WidgetKit
import SwiftUI
import OSLog

private let widgetLogger = Logger(subsystem: "com.luoyun.tokencheck", category: "widget-extension")

private enum WidgetDataCache {
    static var usage: WidgetTodayUsage?
    static var heatmap: WidgetMonthlyHeatmapData?
    static var yearly: WidgetYearlyHeatmapData?
}

private func widgetRefreshInterval() -> Int {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else {
        return 300
    }
    let value = defaults.integer(forKey: "widget_timeline_interval")
    return max(60, value == 0 ? 300 : value)
}

struct TokenWidgetEntry: TimelineEntry {
    let date: Date
    let usage: WidgetTodayUsage?
}

private func readUsageFromAppGroup() -> WidgetTodayUsage? {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
          let data = defaults.data(forKey: "today_usage"),
          let usage = try? JSONDecoder().decode(WidgetTodayUsage.self, from: data)
    else {
        return WidgetDataCache.usage
    }
    WidgetDataCache.usage = usage
    return usage
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
        let t0 = CFAbsoluteTimeGetCurrent()
        let usage = readUsageFromAppGroup()
        let entry = TokenWidgetEntry(date: Date(), usage: usage)
        let nextUpdate = Calendar.current.date(byAdding: .second, value: widgetRefreshInterval(), to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        widgetLogger.debug("TokenCheckWidget getTimeline: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
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
                Text("更新于 \(entry.date, style: .time)")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .padding(.bottom, 2)
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
          let data = defaults.data(forKey: "monthly_heatmap"),
          let heatmap = try? JSONDecoder().decode(WidgetMonthlyHeatmapData.self, from: data)
    else {
        return WidgetDataCache.heatmap
    }
    WidgetDataCache.heatmap = heatmap
    return heatmap
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
        let t0 = CFAbsoluteTimeGetCurrent()
        let data = readHeatmapFromAppGroup()
        let entry = HeatmapWidgetEntry(date: Date(), data: data)
        let nextUpdate = Calendar.current.date(byAdding: .second, value: widgetRefreshInterval(), to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        widgetLogger.debug("HeatmapWidget getTimeline: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
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
                Text("更新于 \(entry.date, style: .time)")
                    .font(.system(size: 6))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                    .padding(.bottom, 1)
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

// MARK: - 大尺寸年度热力图小组件

struct LargeWidgetEntry: TimelineEntry {
    let date: Date
    let usage: WidgetTodayUsage?
    let yearlyData: WidgetYearlyHeatmapData?
}

private func readYearlyHeatmapFromAppGroup() -> WidgetYearlyHeatmapData? {
    // 优先读文件（新路径）
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") {
        let url = container.appendingPathComponent("yearly_heatmap.json")
        if let data = try? Data(contentsOf: url),
           let result = try? JSONDecoder().decode(WidgetYearlyHeatmapData.self, from: data) {
            WidgetDataCache.yearly = result
            return result
        }
    }
    // 回退读 UserDefaults（旧数据，直到下一次 refresh 写入文件）
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
          let data = defaults.data(forKey: "yearly_heatmap"),
          let result = try? JSONDecoder().decode(WidgetYearlyHeatmapData.self, from: data)
    else {
        return WidgetDataCache.yearly
    }
    WidgetDataCache.yearly = result
    return result
}

struct LargeWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LargeWidgetEntry {
        LargeWidgetEntry(date: Date(), usage: nil, yearlyData: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LargeWidgetEntry) -> Void) {
        let usage = readUsageFromAppGroup()
        let yearly = readYearlyHeatmapFromAppGroup()
        completion(LargeWidgetEntry(date: Date(), usage: usage, yearlyData: yearly))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LargeWidgetEntry>) -> Void) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let usage = readUsageFromAppGroup()
        let yearly = readYearlyHeatmapFromAppGroup()
        let entry = LargeWidgetEntry(date: Date(), usage: usage, yearlyData: yearly)
        let nextUpdate = Calendar.current.date(byAdding: .second, value: widgetRefreshInterval(), to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        widgetLogger.debug("LargeWidget getTimeline: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
        completion(timeline)
    }
}

struct LargeWidgetEntryView: View {
    var entry: LargeWidgetEntry

    private var total7Day: Int {
        entry.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if let usage = entry.usage {
                mediumContent(usage)
                if entry.yearlyData != nil {
                    Divider()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
            if let yearly = entry.yearlyData {
                yearlyHeatmapContent(data: yearly)
            } else if entry.usage == nil {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.title)
                        .foregroundStyle(.blue)
                    Text("等待数据...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
            if entry.usage != nil || entry.yearlyData != nil {
                Text("更新于 \(entry.date, style: .time)")
                    .font(.system(size: 6))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
                    .padding(.bottom, 1)
            }
        }
        .containerBackground(.regularMaterial, for: .widget)
    }

    private func mediumContent(_ usage: WidgetTodayUsage) -> some View {
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
            .padding(.horizontal, 6)
            .padding(.top, 4)

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
            .padding(.horizontal, 6)

            if !usage.dailyTokens.isEmpty {
                Divider()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)

                HStack(spacing: 0) {
                    Text("近7天")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("共 \(formatTokens(total7Day))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)

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
                .padding(.horizontal, 6)
                .padding(.bottom, 3)
            }
        }
    }

    private func yearlyHeatmapContent(data: WidgetYearlyHeatmapData) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thresholds = computeThresholds(data: data)
        let grouped = Dictionary(grouping: data.days) { cal.component(.month, from: $0.date) }

        return VStack(spacing: 2) {
            HStack {
                Text("\(data.year) 年 Token 热力图")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Text(formatTokens(data.totalTokens))
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            GeometryReader { geo in
                let colGap: CGFloat = 3
                let rowGap: CGFloat = 2
                let cellGap: CGFloat = 1
                let maxWeeks: CGFloat = 6
                let colWidth = (geo.size.width - 5 * colGap) / 6
                let rowHeight = (geo.size.height - 1 * rowGap) / 2
                let gridHeight = max(10, rowHeight - 10)
                let cellW = (colWidth - (maxWeeks - 1) * cellGap) / maxWeeks
                let cellH = (gridHeight - 6 * cellGap) / 7
                let cellSize = max(2, min(10, min(cellW, cellH)))
                let labelFont = min(8, cellSize * 1.4)

                VStack(spacing: rowGap) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: colGap) {
                            ForEach(0..<6, id: \.self) { col in
                                let month = row * 6 + col + 1
                                let monthDays = (grouped[month] ?? []).sorted(by: { $0.date < $1.date })
                                monthCell(
                                    month: month,
                                    days: monthDays,
                                    cellSize: cellSize,
                                    cellGap: cellGap,
                                    labelFont: labelFont,
                                    thresholds: thresholds,
                                    today: today,
                                    cal: cal
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)

            HStack {
                HStack(spacing: 3) {
                    Text("少")
                        .font(.system(size: 6))
                        .foregroundStyle(.tertiary)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.heatmap1)
                        .frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.heatmap2)
                        .frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.heatmap3)
                        .frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.heatmap4)
                        .frame(width: 8, height: 8)
                    Text("多")
                        .font(.system(size: 6))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("日均 \(formatTokens(data.avgDailyTokens))")
                    .font(.system(size: 7).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }

    private func monthCell(month: Int, days: [WidgetDayTokenData], cellSize: CGFloat, cellGap: CGFloat, labelFont: CGFloat, thresholds: [Int], today: Date, cal: Calendar) -> some View {
        VStack(spacing: 1) {
            Text("\(month)月")
                .font(.system(size: labelFont, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            let actualDays = days.isEmpty
                ? (1...cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: cal.component(.year, from: today), month: month, day: 1))!)!.count).map {
                    WidgetDayTokenData(id: "", date: cal.date(from: DateComponents(year: cal.component(.year, from: today), month: month, day: $0))!, totalTokens: 0)
                }
                : days
            let totalMonthDays = actualDays.count
            let firstWeekday = cal.component(.weekday, from: actualDays[0].date)
            let offset = (firstWeekday + 5) % 7
            let numWeeks = (offset + totalMonthDays + 6) / 7

            VStack(spacing: cellGap) {
                ForEach(0..<7, id: \.self) { row in
                    HStack(spacing: cellGap) {
                        ForEach(0..<Int(numWeeks), id: \.self) { col in
                            let dayIndex = col * 7 + row - offset
                            let cellColor: Color = {
                                guard dayIndex >= 0 && dayIndex < totalMonthDays else { return .clear }
                                let day = actualDays[dayIndex]
                                guard day.date <= today else { return .heatmapEmpty }
                                return colorForTokens(day.totalTokens, thresholds: thresholds)
                            }()
                            RoundedRectangle(cornerRadius: 1)
                                .fill(cellColor)
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func computeThresholds(data: WidgetYearlyHeatmapData) -> [Int] {
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

struct TokenCheckLargeWidget: Widget {
    let kind: String = "TokenCheckLargeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LargeWidgetTimelineProvider()) { entry in
            LargeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Token 年度热力图")
        .description("展示今日 Token 用量和全年热力图。")
        .supportedFamilies([.systemLarge])
    }
}
