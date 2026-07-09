import WidgetKit
import SwiftUI
import OSLog

private let widgetLogger = Logger(subsystem: "com.luoyun.tokencheck", category: "widget-extension")

private func cleanupWidgetTimelineCache() {
    let home = NSHomeDirectory()
    let baseDir = URL(fileURLWithPath: home).appendingPathComponent("SystemData/com.apple.chrono")
    guard FileManager.default.fileExists(atPath: baseDir.path) else { return }
    guard let enumerator = FileManager.default.enumerator(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
    let oldWidgetNames = Set(["TokenCheckWidget", "TokenCheckSmallWidget", "TokenCheckLargeWidget"])
    var deleted = 0
    for case let file as URL in enumerator {
        let parentName = file.deletingLastPathComponent().lastPathComponent
        guard oldWidgetNames.contains(parentName) else { continue }
        try? FileManager.default.removeItem(at: file)
        deleted += 1
    }
    if deleted > 0 {
        widgetLogger.notice("cleaned up \(deleted) old chronod cache files under \(baseDir.path)")
    }
}

private let _widgetTimelineCleanupOnce: Void = {
    cleanupWidgetTimelineCache()
    return ()
}()

private enum WidgetDataCache {
    static var usage: WidgetTodayUsage?
    static var heatmap: WidgetMonthlyHeatmapData?
    static var yearly: WidgetYearlyHeatmapData?
}

private var _lastDataReadTime: Date = .distantPast
private var _cachedWidgetData: CombinedWidgetData?
private let kMinDataReadInterval: TimeInterval = 5

private func readWidgetData() -> CombinedWidgetData? {
    _ = _widgetTimelineCleanupOnce
    let now = Date()
    if now.timeIntervalSince(_lastDataReadTime) < kMinDataReadInterval,
       let cached = _cachedWidgetData {
        return cached
    }
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") else { return nil }
    let url = container.appendingPathComponent("widget_data.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    let result = try? JSONDecoder().decode(CombinedWidgetData.self, from: data)
    _lastDataReadTime = now
    _cachedWidgetData = result
    return result
}

private func widgetRefreshInterval() -> Int {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else {
        return 300
    }
    let value = defaults.integer(forKey: "widgetRefreshInterval")
    return max(60, value == 0 ? 300 : value)
}

private func nextAlignedRefreshDate() -> Date {
    let interval = widgetRefreshInterval()
    let now = Date()
    let seconds = now.timeIntervalSince1970
    let aligned = (floor(seconds / Double(interval)) + 1) * Double(interval)
    return Date(timeIntervalSince1970: aligned)
}

// MARK: - 小组件统计项偏好（从 App Group UserDefaults 读取）

private func widgetStat(forIndex index: Int, defaultVal: String) -> String {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else { return defaultVal }
    return defaults.string(forKey: "widget_stat_\(index)") ?? defaultVal
}

private func widgetDisplayMode() -> String {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else { return "tokens" }
    return defaults.string(forKey: "widget_display_mode") ?? "tokens"
}

private let kDefaultStats: [String] = ["inputTokens", "cacheReadTokens", "outputTokens", "sessionCount"]

struct TokenWidgetEntry: TimelineEntry {
    let date: Date
    let usage: WidgetTodayUsage?
}

private func readUsageFromAppGroup() -> WidgetTodayUsage? {
    // 优先读单一数据文件
    if let combined = readWidgetData(), let usage = combined.todayUsage {
        WidgetDataCache.usage = usage
        return usage
    }
    // 回退读 UserDefaults（旧数据）
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
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        widgetLogger.notice("TokenCheckWidget timeline START at \(df.string(from: Date()), privacy: .public)")
        let usage = readUsageFromAppGroup()
        let entry = TokenWidgetEntry(date: Date(), usage: usage)
        let nextUpdate = nextAlignedRefreshDate()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        widgetLogger.notice("TokenCheckWidget getTimeline: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
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
    String(format: "$%.2f", c)
}

private func statValue(for key: String, usage: WidgetTodayUsage?) -> String {
    guard let usage else { return "—" }
    switch key {
    case "inputTokens":    return formatTokens(usage.inputTokens)
    case "outputTokens":   return formatTokens(usage.outputTokens)
    case "reasoningTokens": return formatTokens(usage.reasoningTokens)
    case "cacheReadTokens": return formatTokens(usage.cacheReadTokens)
    case "cacheWriteTokens": return formatTokens(usage.cacheWriteTokens)
    case "totalTokens":    return formatTokens(usage.totalTokens)
    case "todayCost":      return formatCost(usage.todayCost)
    case "sessionCount":   return "\(usage.sessionCount)"
    case "messageCount":   return "\(usage.messageCount)"
    case "projectCount":   return "\(usage.projectCount)"
    case "additions":      return formatTokens(usage.additions)
    case "deletions":      return formatTokens(usage.deletions)
    case "files":          return "\(usage.files)"
    case "netAdditions":   return formatTokens(usage.additions - usage.deletions)
    default:               return "—"
    }
}

private func statLabel(for key: String) -> String {
    switch key {
    case "inputTokens":    return "输入"
    case "outputTokens":   return "输出"
    case "reasoningTokens": return "推理"
    case "cacheReadTokens": return "缓存"
    case "cacheWriteTokens": return "缓存写入"
    case "totalTokens":    return "总计"
    case "todayCost":      return "费用"
    case "sessionCount":   return "会话"
    case "messageCount":   return "消息"
    case "projectCount":   return "项目"
    case "additions":      return "新增"
    case "deletions":      return "删除"
    case "files":          return "文件"
    case "netAdditions":   return "净增"
    default:               return key
    }
}

private func statColor(for key: String) -> Color {
    switch key {
    case "inputTokens":    return .blue
    case "outputTokens":   return .green
    case "reasoningTokens": return .purple
    case "cacheReadTokens": return .teal
    case "cacheWriteTokens": return .cyan
    case "totalTokens":    return .indigo
    case "todayCost":      return .red
    case "sessionCount":   return .orange
    case "messageCount":   return .yellow
    case "projectCount":   return .purple
    case "additions":      return .green
    case "deletions":      return .red
    case "files":          return .blue
    case "netAdditions":   return .teal
    default:               return .gray
    }
}

struct TokenCheckWidgetEntryView: View {
    var entry: TokenTimelineProvider.Entry

    private var stat1: String { widgetStat(forIndex: 1, defaultVal: kDefaultStats[0]) }
    private var stat2: String { widgetStat(forIndex: 2, defaultVal: kDefaultStats[1]) }
    private var stat3: String { widgetStat(forIndex: 3, defaultVal: kDefaultStats[2]) }
    private var stat4: String { widgetStat(forIndex: 4, defaultVal: kDefaultStats[3]) }

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
                    statItem(statLabel(for: stat1), statValue(for: stat1, usage: usage), statColor(for: stat1))
                    Spacer()
                    statItem(statLabel(for: stat2), statValue(for: stat2, usage: usage), statColor(for: stat2))
                    Spacer()
                    statItem(statLabel(for: stat3), statValue(for: stat3, usage: usage), statColor(for: stat3))
                    Spacer()
                    statItem(statLabel(for: stat4), statValue(for: stat4, usage: usage), statColor(for: stat4))
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
    let kind: String = "TokenCheckWidgetV2"

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
    // 优先读单一数据文件
    if let combined = readWidgetData(), let heatmap = combined.monthlyHeatmap {
        WidgetDataCache.heatmap = heatmap
        return heatmap
    }
    // 回退读 UserDefaults（旧数据）
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
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        widgetLogger.notice("HeatmapWidget getTimeline START at \(df.string(from: Date()), privacy: .public)")
        let data = readHeatmapFromAppGroup()
        let entry = HeatmapWidgetEntry(date: Date(), data: data)
        let nextUpdate = nextAlignedRefreshDate()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        widgetLogger.notice("HeatmapWidget getTimeline: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
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
    let kind: String = "TokenCheckSmallWidgetV2"

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
    // 优先读单一数据文件
    if let combined = readWidgetData(), let yearly = combined.yearlyHeatmap {
        WidgetDataCache.yearly = yearly
        return yearly
    }
    // 回退读文件（旧数据）
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") {
        let url = container.appendingPathComponent("yearly_heatmap.json")
        if let data = try? Data(contentsOf: url),
           let result = try? JSONDecoder().decode(WidgetYearlyHeatmapData.self, from: data) {
            WidgetDataCache.yearly = result
            return result
        }
    }
    // 回退读 UserDefaults（旧数据）
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
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        widgetLogger.notice("LargeWidget timeline START at \(df.string(from: Date()), privacy: .public)")
        let usage = readUsageFromAppGroup()
        let yearly = readYearlyHeatmapFromAppGroup()
        let entry = LargeWidgetEntry(date: Date(), usage: usage, yearlyData: yearly)
        let nextUpdate = nextAlignedRefreshDate()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        widgetLogger.notice("LargeWidget getTimeline: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
        completion(timeline)
    }
}

struct LargeWidgetEntryView: View {
    var entry: LargeWidgetEntry

    private var stat1: String { widgetStat(forIndex: 1, defaultVal: kDefaultStats[0]) }
    private var stat2: String { widgetStat(forIndex: 2, defaultVal: kDefaultStats[1]) }
    private var stat3: String { widgetStat(forIndex: 3, defaultVal: kDefaultStats[2]) }
    private var stat4: String { widgetStat(forIndex: 4, defaultVal: kDefaultStats[3]) }
    private var displayMode: String { widgetDisplayMode() }

    private var total7Day: Int {
        entry.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

    private var total7DayCost: Double {
        entry.usage?.dailyTokens.map(\.dailyCost).reduce(0, +) ?? 0
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
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
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
                statItem(statLabel(for: stat1), statValue(for: stat1, usage: usage), statColor(for: stat1))
                Spacer()
                statItem(statLabel(for: stat2), statValue(for: stat2, usage: usage), statColor(for: stat2))
                Spacer()
                statItem(statLabel(for: stat3), statValue(for: stat3, usage: usage), statColor(for: stat3))
                Spacer()
                statItem(statLabel(for: stat4), statValue(for: stat4, usage: usage), statColor(for: stat4))
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
                    if displayMode == "cost" {
                        Text("共 \(formatCost(total7DayCost))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                    } else {
                        Text("共 \(formatTokens(total7Day))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6)

                if displayMode == "cost" {
                    let maxVal = CGFloat(max(usage.dailyTokens.map(\.dailyCost).max() ?? 0.01, 0.01))
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(usage.dailyTokens.enumerated()), id: \.element.id) { _, item in
                                let ratio = CGFloat(item.dailyCost) / maxVal
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.orange.gradient)
                                    .frame(height: max(4, ratio * geo.size.height))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)
                } else {
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
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
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
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("日均 \(formatTokens(data.avgDailyTokens))")
                    .font(.system(size: 8).monospaced())
                    .foregroundStyle(.secondary)
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
    let kind: String = "TokenCheckLargeWidgetV2"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LargeWidgetTimelineProvider()) { entry in
            LargeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Token 年度热力图")
        .description("展示今日 Token 用量和全年热力图。")
        .supportedFamilies([.systemLarge])
    }
}
