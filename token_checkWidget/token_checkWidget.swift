import WidgetKit
import SwiftUI
import OSLog

private let widgetLogger = Logger(subsystem: "com.luoyun.tokencheck", category: "widget-extension")

private func cleanupWidgetTimelineCache() {
    let home = NSHomeDirectory()
    let baseDir = URL(fileURLWithPath: home).appendingPathComponent("SystemData/com.apple.chrono")
    guard FileManager.default.fileExists(atPath: baseDir.path) else { return }
    guard let enumerator = FileManager.default.enumerator(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
    let oldWidgetNames = Set(["TokenCheckWidget", "TokenCheckSmallWidget", "TokenCheckLargeWidget", "TokenCheckLargeWidgetV2"])
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

private func largeWidgetStat(forIndex index: Int, defaultVal: String) -> String {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else { return defaultVal }
    return defaults.string(forKey: "large_widget_stat_\(index)") ?? defaultVal
}

private func largeWidgetChartRange() -> String {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else { return "7d" }
    return defaults.string(forKey: "large_widget_chart_range") ?? "7d"
}

private let kDefaultStats: [String] = ["inputTokens", "cacheReadTokens", "outputTokens", "sessionCount"]

struct TokenWidgetEntry: TimelineEntry {
    let date: Date
    let usage: WidgetTodayUsage?
}

private func readUsageFromAppGroup() -> WidgetTodayUsage? {
    if let combined = readWidgetData(), let usage = combined.todayUsage {
        WidgetDataCache.usage = usage
        if let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
           let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, forKey: "widget_today_usage_backup")
        }
        return usage
    }
    if let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
       let data = defaults.data(forKey: "widget_today_usage_backup"),
       let usage = try? JSONDecoder().decode(WidgetTodayUsage.self, from: data) {
        WidgetDataCache.usage = usage
        return usage
    }
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
    if n >= 1_000_000_000 {
        String(format: "%.1fB", Double(n) / 1_000_000_000)
    } else if n >= 1_000_000 {
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

private func cacheHitRate(for usage: WidgetTodayUsage) -> String {
    let total = usage.cacheReadTokens + usage.inputTokens
    guard total > 0 else { return "—" }
    return String(format: "%.1f%%", Double(usage.cacheReadTokens) / Double(total) * 100)
}

private func statValue(for key: String, usage: WidgetTodayUsage?) -> String {
    guard let usage else { return "—" }
    switch key {
    case "inputTokens":    return formatTokens(usage.inputTokens)
    case "outputTokens":   return formatTokens(usage.outputTokens)
    case "reasoningTokens": return formatTokens(usage.reasoningTokens)
    case "cacheReadTokens": return formatTokens(usage.cacheReadTokens)
    case "cacheWriteTokens": return formatTokens(usage.cacheWriteTokens)
    case "cacheHitRate":   return cacheHitRate(for: usage)
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
    case "cacheHitRate":   return "缓存命中率"
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
    case "cacheHitRate":   return .teal
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

private func serverConnected() -> Bool {
    UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.bool(forKey: "server_connected") ?? false
}

private func connectionIndicator() -> some View {
    Circle()
        .fill(serverConnected() ? Color.green : Color.red)
        .frame(width: 8, height: 8)
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
                    connectionIndicator()
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
    if let combined = readWidgetData(), let heatmap = combined.monthlyHeatmap {
        WidgetDataCache.heatmap = heatmap
        if let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
           let data = try? JSONEncoder().encode(heatmap) {
            defaults.set(data, forKey: "widget_heatmap_backup")
        }
        return heatmap
    }
    if let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
       let data = defaults.data(forKey: "widget_heatmap_backup"),
       let heatmap = try? JSONDecoder().decode(WidgetMonthlyHeatmapData.self, from: data) {
        WidgetDataCache.heatmap = heatmap
        return heatmap
    }
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
            connectionIndicator()
                .padding(.leading, 4)
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
        .accessibilityHidden(true)
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

private func readYearlyHeatmapFromAppGroup() -> WidgetYearlyHeatmapData? {
    if let combined = readWidgetData(), let yearly = combined.yearlyHeatmap {
        WidgetDataCache.yearly = yearly
        if let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
           let data = try? JSONEncoder().encode(yearly) {
            defaults.set(data, forKey: "widget_yearly_heatmap_backup")
        }
        return yearly
    }
    if let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
       let data = defaults.data(forKey: "widget_yearly_heatmap_backup"),
       let result = try? JSONDecoder().decode(WidgetYearlyHeatmapData.self, from: data) {
        WidgetDataCache.yearly = result
        return result
    }
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") {
        let url = container.appendingPathComponent("yearly_heatmap.json")
        if let data = try? Data(contentsOf: url),
           let result = try? JSONDecoder().decode(WidgetYearlyHeatmapData.self, from: data) {
            WidgetDataCache.yearly = result
            return result
        }
    }
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
          let data = defaults.data(forKey: "yearly_heatmap"),
          let result = try? JSONDecoder().decode(WidgetYearlyHeatmapData.self, from: data)
    else {
        return WidgetDataCache.yearly
    }
    WidgetDataCache.yearly = result
    return result
}

struct LargeWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: LargeWidgetConfigIntent
    let usage: WidgetTodayUsage?
    let yearlyData: WidgetYearlyHeatmapData?
}

struct LargeWidgetTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = LargeWidgetEntry
    typealias Intent = LargeWidgetConfigIntent

    func placeholder(in context: Context) -> LargeWidgetEntry {
        LargeWidgetEntry(date: Date(), configuration: LargeWidgetConfigIntent(), usage: nil, yearlyData: nil)
    }

    func snapshot(for configuration: LargeWidgetConfigIntent, in context: Context) async -> LargeWidgetEntry {
        let usage = readUsageFromAppGroup()
        let yearly = readYearlyHeatmapFromAppGroup()
        return LargeWidgetEntry(date: Date(), configuration: configuration, usage: usage, yearlyData: yearly)
    }

    func timeline(for configuration: LargeWidgetConfigIntent, in context: Context) async -> Timeline<LargeWidgetEntry> {
        let t0 = CFAbsoluteTimeGetCurrent()
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        widgetLogger.notice("LargeWidget timeline START at \(df.string(from: Date()), privacy: .public)")
        let usage = readUsageFromAppGroup()
        let yearly = readYearlyHeatmapFromAppGroup()
        let entry = LargeWidgetEntry(date: Date(), configuration: configuration, usage: usage, yearlyData: yearly)
        let nextUpdate = nextAlignedRefreshDate()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        widgetLogger.notice("LargeWidget getTimeline: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
        return timeline
    }
}

struct LargeWidgetEntryView: View {
    var entry: LargeWidgetEntry

    private var stat1: String {
        let v = entry.configuration.stat1.rawValue
        return !v.isEmpty ? v : largeWidgetStat(forIndex: 1, defaultVal: kDefaultStats[0])
    }
    private var stat2: String {
        let v = entry.configuration.stat2.rawValue
        return !v.isEmpty ? v : largeWidgetStat(forIndex: 2, defaultVal: kDefaultStats[1])
    }
    private var stat3: String {
        let v = entry.configuration.stat3.rawValue
        return !v.isEmpty ? v : largeWidgetStat(forIndex: 3, defaultVal: kDefaultStats[2])
    }
    private var stat4: String {
        let v = entry.configuration.stat4.rawValue
        return !v.isEmpty ? v : largeWidgetStat(forIndex: 4, defaultVal: kDefaultStats[3])
    }

    private var chartRange: String {
        let intentVal = entry.configuration.chartRange.rawValue
        return !intentVal.isEmpty ? intentVal : largeWidgetChartRange()
    }

    private var displayMode: String { widgetDisplayMode() }

    private var chartLabel: String {
        switch chartRange {
        case "30d": return "近30天"
        case "1h":  return "当天分时"
        default:    return "近7天"
        }
    }

    private var chartTotalTokens: Int {
        guard let usage = entry.usage else { return 0 }
        switch chartRange {
        case "30d":
            return usage.dailyTokens.map(\.totalTokens).reduce(0, +)
        case "1h":
            return usage.hourlyTokens.map(\.totalTokens).reduce(0, +)
        default:
            return usage.dailyTokens.suffix(7).map(\.totalTokens).reduce(0, +)
        }
    }

    private var chartTotalCost: Double {
        guard let usage = entry.usage else { return 0 }
        switch chartRange {
        case "30d":
            return usage.dailyTokens.map(\.dailyCost).reduce(0, +)
        case "1h":
            return usage.hourlyTokens.map(\.cost).reduce(0, +)
        default:
            return usage.dailyTokens.suffix(7).map(\.dailyCost).reduce(0, +)
        }
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
                if usage.subscriptionEnabled,
                   let remaining = usage.subscriptionRemaining,
                   let budget = usage.subscriptionBudget,
                   let used = usage.subscriptionUsed,
                   budget > 0 {
                    subscriptionProgressView(used: used, budget: budget, remaining: remaining)
                }
                connectionIndicator()
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

            chartSection(usage)
        }
    }

    @ViewBuilder
    private func chartSection(_ usage: WidgetTodayUsage) -> some View {
        let hasData = chartRange == "1h" ? !usage.hourlyTokens.isEmpty : !usage.dailyTokens.isEmpty

        if hasData {
            Divider()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)

            HStack(spacing: 0) {
                Text(chartLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if displayMode == "cost" {
                    Text("共 \(formatCost(chartTotalCost))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                } else {
                    Text("共 \(formatTokens(chartTotalTokens))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)

            if chartRange == "1h" {
                hourlyChartView(usage)
                    .accessibilityHidden(true)
            } else if chartRange == "30d" {
                dailyChartView(usage, days: 30)
                    .accessibilityHidden(true)
            } else {
                dailyChartView(usage, days: 7)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func dailyChartView(_ usage: WidgetTodayUsage, days: Int) -> some View {
        let data = Array(usage.dailyTokens.suffix(days))
        if displayMode == "cost" {
            dailyCostChart(data: data, days: days)
        } else {
            dailyTokenChart(data: data)
        }
    }

    private func dailyCostChart(data: [WidgetDayTokenData], days: Int) -> some View {
        GeometryReader { geo in
            let maxVal = CGFloat(max(data.map(\.dailyCost).max() ?? 0.01, 0.01))
            HStack(spacing: days > 10 ? 1 : 2) {
                ForEach(Array(data.enumerated()), id: \.element.id) { _, item in
                    let ratio = CGFloat(item.dailyCost) / maxVal
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.orange.gradient)
                        .frame(height: max(2, ratio * geo.size.height))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
    }

    private func dailyTokenChart(data: [WidgetDayTokenData]) -> some View {
        GeometryReader { geo in
            let maxVal = max(data.map(\.totalTokens).max() ?? 1, 1)
            HStack(spacing: 2) {
                ForEach(Array(data.enumerated()), id: \.element.id) { _, item in
                    let ratio = CGFloat(item.totalTokens) / CGFloat(maxVal)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.blue.gradient)
                        .frame(height: max(2, ratio * geo.size.height))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
    }

    @ViewBuilder
    private func hourlyChartView(_ usage: WidgetTodayUsage) -> some View {
        if displayMode == "cost" {
            hourlyCostChart(data: usage.hourlyTokens)
        } else {
            hourlyTokenChart(data: usage.hourlyTokens)
        }
    }

    private func hourlyCostChart(data: [WidgetHourlyData]) -> some View {
        GeometryReader { geo in
            let maxVal = CGFloat(max(data.map(\.cost).max() ?? 0.01, 0.01))
            HStack(spacing: 1) {
                ForEach(0..<data.count, id: \.self) { idx in
                    let ratio = CGFloat(data[idx].cost) / maxVal
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.orange.gradient)
                        .frame(height: max(2, ratio * geo.size.height))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
    }

    private func hourlyTokenChart(data: [WidgetHourlyData]) -> some View {
        GeometryReader { geo in
            let maxVal = max(data.map(\.totalTokens).max() ?? 1, 1)
            HStack(spacing: 1) {
                ForEach(0..<data.count, id: \.self) { idx in
                    let ratio = CGFloat(data[idx].totalTokens) / CGFloat(maxVal)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.blue.gradient)
                        .frame(height: max(2, ratio * geo.size.height))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
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
                .accessibilityHidden(true)
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

    private func subscriptionProgressView(used: Double, budget: Double, remaining: Double) -> some View {
        let ratio = min(used / budget, 1.0)
        let barColor: Color = ratio < 0.5 ? .green : (ratio < 0.8 ? .orange : .red)
        let pct = Int(ratio * 100)
        return HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 48, height: 8)
                Capsule()
                    .fill(barColor.gradient)
                    .frame(width: max(4, 48 * ratio), height: 8)
            }
            Text("\(pct)%")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(barColor)
        }
        .padding(.leading, 4)
    }
}

struct TokenCheckLargeWidget: Widget {
    let kind: String = "TokenCheckLargeWidgetV3"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: LargeWidgetConfigIntent.self,
            provider: LargeWidgetTimelineProvider()
        ) { entry in
            LargeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Token 年度热力图")
        .description("展示今日 Token 用量和全年热力图。")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Clash 订阅流量小组件

private func readClashTrafficData() -> ClashTrafficData? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") else { return nil }
    let url = container.appendingPathComponent("clash_traffic.json")
    guard let data = try? Data(contentsOf: url),
          let result = try? JSONDecoder().decode(ClashTrafficData.self, from: data),
          result.isValid else { return nil }
    return result
}

struct ClashTrafficEntry: TimelineEntry {
    let date: Date
    let data: ClashTrafficData?
}

struct ClashTrafficTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClashTrafficEntry {
        ClashTrafficEntry(date: Date(), data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClashTrafficEntry) -> Void) {
        completion(ClashTrafficEntry(date: Date(), data: readClashTrafficData()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClashTrafficEntry>) -> Void) {
        let data = readClashTrafficData()
        let entry = ClashTrafficEntry(date: Date(), data: data)
        let nextUpdate = nextAlignedRefreshDate()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

private func formatTraffic(_ bytes: Int64, _ decimal: Int = 4) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var unitIndex = 0
    while abs(value) >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    return String(format: "%.\(decimal)f %@", value, units[unitIndex])
}

private func formatExpire(_ timestamp: Int64) -> String {
    guard timestamp > 0 else { return "不限" }
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    return df.string(from: date)
}

struct ClashTrafficEntryView: View {
    var entry: ClashTrafficEntry

    var body: some View {
        if let data = entry.data {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.blue)
                        .font(.headline)
                    Text(data.label)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(data.progress * 100))%")
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(progressColor(data.progress))
                }

                ProgressView(value: data.progress)
                    .tint(progressColor(data.progress))
                    .padding(.vertical, 2)

                HStack {
                    Text("\(formatTraffic(data.used)) / \(formatTraffic(data.total, 0))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline)
                        .foregroundStyle(progressColor(data.progress))
                    Text("剩余 ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    + Text(formatTraffic(data.remaining))
                        .font(.subheadline.monospaced().bold())
                        .foregroundStyle(progressColor(data.progress))
                    Spacer()
                }

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(formatExpire(data.expire)) 到期")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                Text("更新于 \(entry.date, style: .time)")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .containerBackground(.regularMaterial, for: .widget)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title)
                    .foregroundStyle(.blue)
                Text("Clash 数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("等待数据...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .containerBackground(.regularMaterial, for: .widget)
        }
    }

    private func progressColor(_ p: Double) -> Color {
        if p < 0.5 { return .green }
        if p < 0.8 { return .orange }
        return .red
    }
}

struct ClashTrafficWidget: Widget {
    let kind: String = "ClashTrafficWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClashTrafficTimelineProvider()) { entry in
            ClashTrafficEntryView(entry: entry)
        }
        .configurationDisplayName("Clash 流量")
        .description("显示 Clash 订阅的流量使用情况和到期时间。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
