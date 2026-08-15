import Foundation
import OSLog

/// DSH 小组件数据构建：生成与 opencode 同构的 CombinedWidgetData（今日用量 + 月/年热力图），
/// 由主 app 在刷新时写入 App Group 的 dsh_widget_data.json，小组件按数据源设置读取。
final class DshWidgetDataService {
    static let shared = DshWidgetDataService()

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "dsh-widget")

    /// 构建 DSH 版 widget 数据（事件级；zstd 不可用或日志缺失时返回 nil）
    func fetchWidgetData() -> CombinedWidgetData? {
        guard case .success(let dataSource) = DshService.shared.loadDetailedData(), dataSource.isFull else {
            return nil
        }
        return CombinedWidgetData(
            todayUsage: buildTodayUsage(dataSource),
            monthlyHeatmap: buildMonthHeatmap(dataSource),
            yearlyHeatmap: buildYearlyHeatmap(dataSource)
        )
    }

    // MARK: - 今日用量

    private func buildTodayUsage(_ ds: DshDetailedDataSource) -> TodayUsage {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        var input = 0, output = 0, cacheRead = 0, reasoning = 0, cacheWrite = 0
        var activeSessions = Set<String>()
        var activeProjects = Set<String>()
        var hourly: [Int: Int] = [:]

        let sessionByID = Dictionary(uniqueKeysWithValues: ds.snapshot.sessions.map { ($0.id, $0) })
        for event in ds.events where event.time >= todayStart && event.time < todayEnd {
            input += event.inputTokens
            output += event.outputTokens
            cacheRead += event.cacheReadTokens
            reasoning += event.reasoningTokens
            cacheWrite += event.cacheWriteTokens
            activeSessions.insert(event.sessionID)
            if let stat = sessionByID[event.sessionID] {
                activeProjects.insert(stat.cwd)
            }
            hourly[cal.component(.hour, from: event.time), default: 0] += event.totalTokensForAttribution
        }
        // 兜底：投影缓存里今天创建的会话（尚无事件时）
        for stat in ds.snapshot.sessions where stat.createdAt >= todayStart && stat.createdAt < todayEnd {
            activeSessions.insert(stat.id)
            activeProjects.insert(stat.cwd)
        }

        let sessionCount = activeSessions.count
        let projectCount = activeProjects.count
        let messageCount = ds.messageCount(forSessionIDs: activeSessions)

        // 今日费用估算：统一按当前时间取价
        let prices = ModelPricingStore.price(
            forModelId: ds.defaultModel.modelId,
            variant: ds.defaultModel.variant,
            providerID: ds.defaultModel.providerID,
            at: now,
            rules: ds.pricingRules
        )
        let todayCost = costOf(
            miss: input, hit: cacheRead, out: output, reason: reasoning,
            prices: prices
        )

        // 近 30 天（按天聚合 + 按天取价）
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        var dailyMap: [Date: (tokens: Int, cost: Double)] = [:]
        for event in ds.events where event.time >= thirtyDaysAgo {
            let day = cal.startOfDay(for: event.time)
            var item = dailyMap[day] ?? (0, 0)
            item.tokens += event.totalTokensForAttribution
            let dayPrices = ModelPricingStore.price(
                forModelId: ds.defaultModel.modelId,
                variant: ds.defaultModel.variant,
                providerID: ds.defaultModel.providerID,
                at: day,
                rules: ds.pricingRules
            )
            item.cost += costOf(
                miss: event.inputTokens, hit: event.cacheReadTokens,
                out: event.outputTokens, reason: event.reasoningTokens,
                prices: dayPrices
            )
            dailyMap[day] = item
        }
        var dailyTokens: [DayTokenData] = []
        for i in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: i, to: thirtyDaysAgo) else { continue }
            let item = dailyMap[cal.startOfDay(for: day)] ?? (0, 0)
            dailyTokens.append(DayTokenData(
                id: df.string(from: day),
                date: day,
                totalTokens: item.tokens,
                dailyCost: item.cost
            ))
        }

        let hourlyTokens = (0..<24).map { hour in
            HourlyData(hour: hour, totalTokens: hourly[hour] ?? 0, cost: 0)
        }

        return TodayUsage(
            totalTokens: input + output + reasoning + cacheRead + cacheWrite,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            cacheWriteTokens: cacheWrite,
            sessionCount: sessionCount,
            messageCount: messageCount,
            projectCount: projectCount,
            additions: 0,
            deletions: 0,
            files: 0,
            dailyTokens: dailyTokens,
            hourlyTokens: hourlyTokens,
            todayCost: todayCost
        )
    }

    // MARK: - 热力图

    private func buildMonthHeatmap(_ ds: DshDetailedDataSource) -> MonthlyHeatmapData? {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        guard let monthStart = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return nil }

        let firstWeekday = cal.component(.weekday, from: monthStart)
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 28

        var daily: [Int: Int] = [:]
        for event in ds.events where event.time >= monthStart && event.time < monthEnd {
            daily[cal.component(.day, from: event.time), default: 0] += event.totalTokensForAttribution
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        var days: [DayTokenData] = []
        var total = 0
        for day in 1...daysInMonth {
            guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
            let tokens = daily[day] ?? 0
            days.append(DayTokenData(id: df.string(from: date), date: date, totalTokens: tokens))
            total += tokens
        }

        return MonthlyHeatmapData(
            year: year,
            month: month,
            totalTokens: total,
            avgDailyTokens: daysInMonth > 0 ? total / daysInMonth : 0,
            days: days,
            firstWeekday: firstWeekday
        )
    }

    private func buildYearlyHeatmap(_ ds: DshDetailedDataSource) -> YearlyHeatmapData? {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = cal.date(byAdding: .year, value: 1, to: yearStart) else { return nil }

        let firstWeekday = cal.component(.weekday, from: yearStart)
        let totalDays = cal.range(of: .day, in: .year, for: yearStart)?.count ?? 365

        var daily: [Int: Int] = [:]
        for event in ds.events where event.time >= yearStart && event.time < yearEnd {
            daily[cal.ordinality(of: .day, in: .year, for: event.time) ?? 0, default: 0] += event.totalTokensForAttribution
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        var days: [DayTokenData] = []
        var total = 0
        for day in 1...totalDays {
            guard let date = cal.date(from: DateComponents(year: year, month: 1, day: day)) else { continue }
            let tokens = daily[day] ?? 0
            days.append(DayTokenData(id: df.string(from: date), date: date, totalTokens: tokens))
            total += tokens
        }

        return YearlyHeatmapData(
            year: year,
            totalTokens: total,
            avgDailyTokens: totalDays > 0 ? total / totalDays : 0,
            days: days,
            firstWeekday: firstWeekday,
            totalDays: totalDays
        )
    }

    // MARK: - Helpers

    private func costOf(miss: Int, hit: Int, out: Int, reason: Int, prices: (inputMiss: Double, cacheHit: Double, output: Double, reasoning: Double)) -> Double {
        Double(miss) / 1_000_000 * prices.inputMiss
            + Double(hit) / 1_000_000 * prices.cacheHit
            + Double(out) / 1_000_000 * prices.output
            + Double(reason) / 1_000_000 * prices.reasoning
    }
}
