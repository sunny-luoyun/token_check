import Foundation
import OSLog
import SQLite3

struct DayTokenData: Identifiable, Codable {
    let id: String
    let date: Date
    let totalTokens: Int
    let dailyCost: Double

    enum CodingKeys: String, CodingKey {
        case id, date, totalTokens, dailyCost
    }

    init(id: String, date: Date, totalTokens: Int, dailyCost: Double = 0) {
        self.id = id
        self.date = date
        self.totalTokens = totalTokens
        self.dailyCost = dailyCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        dailyCost = try container.decodeIfPresent(Double.self, forKey: .dailyCost) ?? 0
    }
}

struct HourlyData: Codable {
    let hour: Int
    let totalTokens: Int
    let cost: Double
}

struct TodayUsage: Codable {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let cacheWriteTokens: Int
    let sessionCount: Int
    let messageCount: Int
    let projectCount: Int
    let additions: Int
    let deletions: Int
    let files: Int
    let dailyTokens: [DayTokenData]
    let hourlyTokens: [HourlyData]
    let todayCost: Double
    let subscriptionRemaining: Double?
    let subscriptionBudget: Double?
    let subscriptionUsed: Double?
    let subscriptionPeriodEnd: Double?
    let subscriptionEnabled: Bool

    init(
        totalTokens: Int, inputTokens: Int, outputTokens: Int,
        cacheReadTokens: Int, reasoningTokens: Int, cacheWriteTokens: Int,
        sessionCount: Int, messageCount: Int, projectCount: Int,
        additions: Int, deletions: Int, files: Int,
        dailyTokens: [DayTokenData], hourlyTokens: [HourlyData],
        todayCost: Double,
        subscriptionRemaining: Double? = nil,
        subscriptionBudget: Double? = nil,
        subscriptionUsed: Double? = nil,
        subscriptionPeriodEnd: Double? = nil,
        subscriptionEnabled: Bool = false
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.projectCount = projectCount
        self.additions = additions
        self.deletions = deletions
        self.files = files
        self.dailyTokens = dailyTokens
        self.hourlyTokens = hourlyTokens
        self.todayCost = todayCost
        self.subscriptionRemaining = subscriptionRemaining
        self.subscriptionBudget = subscriptionBudget
        self.subscriptionUsed = subscriptionUsed
        self.subscriptionPeriodEnd = subscriptionPeriodEnd
        self.subscriptionEnabled = subscriptionEnabled
    }
}

struct MonthlyHeatmapData: Codable {
    let year: Int
    let month: Int
    let totalTokens: Int
    let avgDailyTokens: Int
    let days: [DayTokenData]
    let firstWeekday: Int
}

struct YearlyHeatmapData: Codable {
    let year: Int
    let totalTokens: Int
    let avgDailyTokens: Int
    let days: [DayTokenData]
    let firstWeekday: Int
    let totalDays: Int
}

struct CombinedWidgetData: Codable {
    let todayUsage: TodayUsage?
    let monthlyHeatmap: MonthlyHeatmapData?
    let yearlyHeatmap: YearlyHeatmapData?
}

final class WidgetDataService {
    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "widget-data")
    private let healthSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    func checkCloudHealth() -> Bool {
        let url = URL(string: "https://opencode.ai/zen/go/v1/models")!
        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        let task = healthSession.dataTask(with: url) { _, response, error in
            if error == nil,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                healthy = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return healthy
    }

    func fetchTodayUsage() -> TodayUsage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        defer { self.logger.debug("fetchTodayUsage SQL: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms") }

        let todayStart = todayStartMilliseconds()
        let thirtyDaysAgo = todayStart - 29 * 86_400 * 1000

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = df.string(from: Date())

        let sessionRow = fetchTodayRow(db, todayStart)
        let todayFromEvents = TokenDeltaTracker.shared.dailyConsumption[todayKey]
        let trackerCoversToday = Self.trackerCovers(todayKey)

        let input: Int
        let output: Int
        let cacheRead: Int
        let reasoning: Int
        let cacheWrite: Int
        let sessionCount: Int
        let additions: Int
        let deletions: Int
        let files: Int

        if trackerCoversToday {
            // 事件时间口径：今天的消耗归属今天
            let tracker = TokenDeltaTracker.shared
            let tc = tracker.dailyConsumption[todayKey] ?? .zero
            input = tc.tokensInput
            output = tc.tokensOutput
            cacheRead = tc.tokensCacheRead
            reasoning = tc.tokensReasoning
            cacheWrite = tc.tokensCacheWrite
            let todayParts = Self.dateParts(from: todayKey)
            sessionCount = tracker.activeSessionCount(year: todayParts.year, month: todayParts.month, day: todayParts.day)
            let todaySummary = tracker.summary(year: todayParts.year, month: todayParts.month, day: todayParts.day)
            additions = todaySummary.additions
            deletions = todaySummary.deletions
            files = todaySummary.files
        } else if let row = sessionRow {
            // session 表兜底（事件缺失的历史日期）
            input = row.input
            output = row.output
            cacheRead = row.cacheRead
            reasoning = row.reasoning
            cacheWrite = row.cacheWrite
            sessionCount = row.sessions
            additions = row.additions
            deletions = row.deletions
            files = row.files
        } else if let events = todayFromEvents {
            // 兜底：使用事件表累计数据
            input = events.tokensInput
            output = events.tokensOutput
            cacheRead = events.tokensCacheRead
            reasoning = events.tokensReasoning
            cacheWrite = events.tokensCacheWrite
            sessionCount = 0
            additions = 0
            deletions = 0
            files = 0
        } else {
            return nil
        }

        let messageCount = fetchTodayMessageCount(db, todayStart)

        let todayCost: Double
        if trackerCoversToday {
            let parts = Self.dateParts(from: todayKey)
            todayCost = TokenDeltaTracker.shared.consumptionCost(year: parts.year, month: parts.month, day: parts.day)
        } else {
            todayCost = fetchTodayCost(db, todayStart)
        }

        let projectCount: Int
        if trackerCoversToday {
            let parts = Self.dateParts(from: todayKey)
            projectCount = TokenDeltaTracker.shared.activeProjectCount(year: parts.year, month: parts.month, day: parts.day)
        } else {
            projectCount = fetchTodayProjectCount(db, todayStart)
        }

        // 事件时间口径优先：事件覆盖的日期用 tracker，未覆盖的日期用 session 表兜底
        let eventSeries = TokenDeltaTracker.shared.dailyConsumptionSeries(
            from: Date(timeIntervalSince1970: TimeInterval(thirtyDaysAgo) / 1000),
            to: Date()
        )
        let eventCostSeries = TokenDeltaTracker.shared.dailyCostSeries(
            from: Date(timeIntervalSince1970: TimeInterval(thirtyDaysAgo) / 1000),
            to: Date()
        )

        let sqlDailyTokens = fetchDailyTokens(db, thirtyDaysAgo) ?? []
        let sqlDailyCosts = fetchDailyCosts(db, cutoff: thirtyDaysAgo)

        var mergedTokens: [String: DayTokenData] = [:]
        for item in sqlDailyTokens {
            let key = Self.eventDateKey(for: item.date)
            mergedTokens[key] = item
        }
        for (key, tokens) in eventSeries {
            guard let date = dailyDateFrom(key) else { continue }
            mergedTokens[key] = DayTokenData(id: key, date: date, totalTokens: tokens.total)
        }
        var mergedCosts: [String: Double] = sqlDailyCosts
        for (key, cost) in eventCostSeries {
            mergedCosts[key] = cost
        }

        let dailyTokens = fillMissingDays(
            mergedTokens.values.sorted { $0.date < $1.date },
            since: thirtyDaysAgo
        )
        let dailyTokensWithCost = dailyTokens.map { day in
            let key = Self.eventDateKey(for: day.date)
            return DayTokenData(id: day.id, date: day.date, totalTokens: day.totalTokens, dailyCost: mergedCosts[key] ?? 0)
        }

        let hourlyTokens = fetchTodayHourlyUsage(db, todayStart)

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
            additions: additions,
            deletions: deletions,
            files: files,
            dailyTokens: dailyTokensWithCost,
            hourlyTokens: hourlyTokens,
            todayCost: todayCost
        )
    }

    func fetchYearlyData() -> YearlyHeatmapData? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        defer { self.logger.debug("fetchYearlyData SQL: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms") }

        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)

        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = cal.date(byAdding: .year, value: 1, to: yearStart) else { return nil }

        let startMs = Int64(yearStart.timeIntervalSince1970 * 1000)
        let endMs = Int64(yearEnd.timeIntervalSince1970 * 1000)
        let firstWeekday = cal.component(.weekday, from: yearStart)
        let totalDays = cal.range(of: .day, in: .year, for: yearStart)!.count

        let sql = """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(SUM(tokens_input + tokens_cache_read + tokens_output + tokens_reasoning + tokens_cache_write), 0) AS total
            FROM \(sessionSource)
            WHERE time_created >= ? AND time_created < ?
            GROUP BY day
            ORDER BY day
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)

        var existing: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let day = String(cString: cStr)
            existing[day] = Int(sqlite3_column_int64(stmt, 1))
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        // 事件时间口径优先：事件覆盖的日期用 tracker 值覆盖
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let eventSeries = TokenDeltaTracker.shared.dailyConsumptionSeries(from: yearStart, to: yearEnd.addingTimeInterval(-1))
        for (key, tokens) in eventSeries where covered.contains(key) {
            if let d = df.date(from: key) {
                existing[key] = tokens.total
            }
        }
        var days: [DayTokenData] = []
        var totalTokens = 0

        for day in 1...totalDays {
            guard let date = cal.date(from: DateComponents(year: year, month: 1, day: day)) else { continue }
            let key = df.string(from: date)
            let tokens = existing[key] ?? 0
            days.append(.init(id: key, date: date, totalTokens: tokens))
            totalTokens += tokens
        }

        let avg = totalDays > 0 ? totalTokens / totalDays : 0
        return YearlyHeatmapData(
            year: year,
            totalTokens: totalTokens,
            avgDailyTokens: avg,
            days: days,
            firstWeekday: firstWeekday,
            totalDays: totalDays
        )
    }

    func fetchMonthData() -> MonthlyHeatmapData? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        defer { self.logger.debug("fetchMonthData SQL: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms") }

        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)

        guard let monthStart = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return nil }

        let startMs = Int64(monthStart.timeIntervalSince1970 * 1000)
        let endMs = Int64(monthEnd.timeIntervalSince1970 * 1000)
        let firstWeekday = cal.component(.weekday, from: monthStart)
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)!.count

        let sql = """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(SUM(tokens_input + tokens_cache_read + tokens_output + tokens_reasoning + tokens_cache_write), 0) AS total
            FROM \(sessionSource)
            WHERE time_created >= ? AND time_created < ?
            GROUP BY day
            ORDER BY day
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)

        var existing: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let day = String(cString: cStr)
            existing[day] = Int(sqlite3_column_int64(stmt, 1))
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        // 事件时间口径优先：事件覆盖的日期用 tracker 值覆盖
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let eventSeries = TokenDeltaTracker.shared.dailyConsumptionSeries(from: monthStart, to: monthEnd.addingTimeInterval(-1))
        for (key, tokens) in eventSeries where covered.contains(key) {
            if let date = df.date(from: key) {
                existing[key] = tokens.total
            }
        }
        var days: [DayTokenData] = []
        var totalTokens = 0

        for day in 1...daysInMonth {
            guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
            let key = df.string(from: date)
            let tokens = existing[key] ?? 0
            days.append(.init(id: key, date: date, totalTokens: tokens))
            totalTokens += tokens
        }

        let avg = daysInMonth > 0 ? totalTokens / daysInMonth : 0
        return MonthlyHeatmapData(
            year: year,
            month: month,
            totalTokens: totalTokens,
            avgDailyTokens: avg,
            days: days,
            firstWeekday: firstWeekday
        )
    }

    private func dailyDateFrom(_ key: String) -> Date? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: key)
    }

    private func fillMissingDays(_ tokens: [DayTokenData], since cutoffMs: Int64) -> [DayTokenData] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoffMs) / 1000)
        let dayCount = cal.dateComponents([.day], from: cutoffDate, to: today).day! + 1

        let existing = Dictionary(uniqueKeysWithValues: tokens.map { (cal.startOfDay(for: $0.date), $0) })
        var result: [DayTokenData] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        for i in 0..<dayCount {
            guard let date = cal.date(byAdding: .day, value: i, to: cutoffDate) else { continue }
            let start = cal.startOfDay(for: date)
            if let item = existing[start] {
                result.append(item)
            } else {
                result.append(DayTokenData(id: df.string(from: date), date: date, totalTokens: 0))
            }
        }
        return result
    }

    private func fetchTodayRow(_ db: OpaquePointer, _ cutoff: Int64) -> (input: Int, output: Int, cacheRead: Int, reasoning: Int, cacheWrite: Int, additions: Int, deletions: Int, files: Int, sessions: Int)? {
        let sql = """
            SELECT COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COALESCE(SUM(tokens_reasoning), 0),
                   COALESCE(SUM(tokens_cache_write), 0),
                   COALESCE(SUM(summary_additions), 0),
                   COALESCE(SUM(summary_deletions), 0),
                   COALESCE(SUM(summary_files), 0),
                   COUNT(*)
            FROM \(sessionSource)
            WHERE time_created > ?
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (int(stmt, 0), int(stmt, 1), int(stmt, 2), int(stmt, 3), int(stmt, 4), int(stmt, 5), int(stmt, 6), int(stmt, 7), int(stmt, 8))
    }

    private func fetchTodayCost(_ db: OpaquePointer, _ cutoff: Int64) -> Double {
        let sql = "SELECT COALESCE(SUM(cost), 0) FROM \(sessionSource) WHERE time_created > ?"
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    private func fetchTodayMessageCount(_ db: OpaquePointer, _ cutoff: Int64) -> Int {
        let sql = "SELECT COUNT(*) FROM \(messageSource) WHERE time_created > ?"
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func fetchTodayProjectCount(_ db: OpaquePointer, _ cutoff: Int64) -> Int {
        let sql = "SELECT COUNT(DISTINCT project_id) FROM \(sessionSource) WHERE time_created > ?"
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func fetchDailyTokens(_ db: OpaquePointer, _ cutoff: Int64) -> [DayTokenData]? {
        let sql = """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(SUM(tokens_input + tokens_cache_read + tokens_output + tokens_reasoning + tokens_cache_write), 0) AS total
            FROM \(sessionSource)
            WHERE time_created > ?
            GROUP BY day
            ORDER BY day
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        var tokens: [DayTokenData] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let dateStr = String(cString: cStr)
            let total = Int(sqlite3_column_int64(stmt, 1))
            guard let date = df.date(from: dateStr) else { continue }
            tokens.append(DayTokenData(id: dateStr, date: date, totalTokens: total))
        }
        return tokens.isEmpty ? nil : tokens
    }

    private func fetchDailyCosts(_ db: OpaquePointer, cutoff: Int64) -> [String: Double] {
        let sql = """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(SUM(cost), 0)
            FROM \(sessionSource)
            WHERE time_created > ?
            GROUP BY day
            ORDER BY day
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        var result: [String: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayStr = text(stmt, 0) else { continue }
            result[dayStr] = sqlite3_column_double(stmt, 1)
        }
        return result
    }

    private func fetchTodayHourlyUsage(_ db: OpaquePointer, _ todayStart: Int64) -> [HourlyData] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = df.string(from: Date())
        let hourlyData = TokenDeltaTracker.shared.hourlyConsumption

        return (0..<24).map { hour in
            let key = "\(todayKey)/\(String(format: "%02d", hour))"
            let total = hourlyData[key]?.total ?? 0
            return HourlyData(hour: hour, totalTokens: total, cost: 0)
        }
    }

    // MARK: - 订阅计费统计

    func computeSubscriptionData() -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)? {
        guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
              defaults.bool(forKey: "subscriptionEnabled") else { return nil }

        // 优先使用官方 API
        let apiKey = defaults.string(forKey: "opencodeApiKey") ?? ""
        if !apiKey.isEmpty {
            return computeOfficialUsage(defaults: defaults, apiKey: apiKey)
        }

        // Fallback: 旧的本地计算方式
        return computeLocalUsage(defaults: defaults)
    }

    /// 官方 API 用量（同步调用，后台线程执行）
    private func computeOfficialUsage(defaults: UserDefaults, apiKey: String) -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (used: Double, budget: Double, remaining: Double, periodEnd: Double)?

        Task {
            let usage = await OpenCodeUsageService.shared.fetchUsage(apiKey: apiKey)
            if let usage {
                let tier = defaults.double(forKey: "subscriptionTier")
                let budget = tier > 0 ? tier : 60.0
                let used = budget * Double(usage.monthlyPercent) / 100.0
                let remaining = max(budget - used, 0)
                let periodEnd = usage.monthlyResetsAt.map { $0.timeIntervalSince1970 * 1000 } ?? 0
                result = (used, budget, remaining, periodEnd)
                logger.debug("官方 API 用量: \(usage.monthlyPercent)% = $\(String(format: "%.2f", used)) / $\(String(format: "%.0f", budget))")
            } else {
                logger.warning("官方 API 失败，fallback 到本地计算")
                result = computeLocalUsage(defaults: defaults)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)

        return result
    }

    /// 旧的本地计算方式（向后兼容）
    private func computeLocalUsage(defaults: UserDefaults) -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)? {
        let startMs = defaults.double(forKey: "subscriptionPeriodStart")
        let durationDays = defaults.integer(forKey: "subscriptionPeriodDurationDays")
        let budget = defaults.double(forKey: "subscriptionBudget")
        guard startMs > 0, durationDays >= 1, budget > 0 else { return nil }

        let periodEnd = startMs + Double(durationDays) * 86_400_000

        let used = fetchOpenCodeGoCost(startDateMs: Int64(startMs))
                 + fetchDshOpencodeGoEstimatedCost(startDateMs: Int64(startMs))
        logger.debug("本地估算用量: $\(String(format: "%.2f", used)) / $\(String(format: "%.0f", budget))")

        return (used, budget, max(budget - used, 0), periodEnd)
    }

    // MARK: - 旧的本地计算方式（仅在无 API Key 时 fallback 使用）

    /// opencode 费用分解（含回滚调整；失败抛错）
    private func fetchOpenCodeGoCost(startDateMs: Int64) -> Double {
        guard let db = openDB() else { return 0 }
        defer { sqlite3_close(db) }

        let sql = "SELECT COALESCE(SUM(cost), 0) FROM \(sessionSource) WHERE (time_created >= ? AND json_extract(model, '$.providerID') = 'opencode-go') OR id IN ('ses_0d81551dbffeGhQWgB810uTX0E', 'ses_0c0d87444ffeyoF1ANsSNgLwJh')"
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startDateMs)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    /// DSH 侧 opencode-go 事件消耗估算（DSH 不记录真实费用，按价格规则 × tokens）
    private func fetchDshOpencodeGoEstimatedCost(startDateMs: Int64) -> Double {
        guard case .success(let ds) = DshService.shared.loadDetailedData(), ds.isFull else { return 0 }
        let startDate = Date(timeIntervalSince1970: Double(startDateMs) / 1000)
        let rules = ds.pricingRules
        var total = 0.0
        for event in ds.events {
            guard event.providerID == "opencode-go", event.time >= startDate else { continue }
            let prices = ModelPricingStore.price(
                forModelId: event.modelId,
                variant: "default",
                providerID: event.providerID,
                at: event.time,
                rules: rules
            )
            total += Double(event.inputTokens) / 1_000_000 * prices.inputMiss
                   + Double(event.cacheReadTokens) / 1_000_000 * prices.cacheHit
                   + Double(event.outputTokens) / 1_000_000 * prices.output
                   + Double(event.reasoningTokens) / 1_000_000 * prices.reasoning
        }
        logger.debug("订阅 DSH 估算: \(String(format: "%.2f", total))")
        return total
    }

    private var hasDeveco = false

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(AppDatabase.opencodePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else { return nil }
        sqlite3_busy_timeout(db, 5000)

        hasDeveco = false
        if AppDatabase.devecoExists {
            let attachSQL = "ATTACH DATABASE '\(AppDatabase.devecoPath)' AS deveco"
            let rc = sqlite3_exec(db, attachSQL, nil, nil, nil)
            hasDeveco = (rc == SQLITE_OK)
            if !hasDeveco {
                logger.error("ATTACH deveco.db 失败: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        return db
    }

    private let sessionCols = "id, project_id, parent_id, slug, directory, title, version, share_url, summary_additions, summary_deletions, summary_files, summary_diffs, revert, permission, time_created, time_updated, time_compacting, time_archived, workspace_id, path, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, metadata"

    private var sessionSource: String {
        hasDeveco
            ? "(SELECT \(sessionCols) FROM main.session UNION ALL SELECT \(sessionCols) FROM deveco.session) AS session"
            : "session"
    }

    private var messageSource: String {
        hasDeveco
            ? "(SELECT * FROM main.message UNION ALL SELECT * FROM deveco.message) AS message"
            : "message"
    }

    private func todayStartMilliseconds() -> Int64 {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return Int64(today.timeIntervalSince1970 * 1000)
    }

    /// 事件表覆盖的日期走事件口径；未覆盖的日期走 session 表兜底
    private static func trackerCovers(_ dateKey: String) -> Bool {
        TokenDeltaTracker.shared.coveredDateKeys().contains(dateKey)
    }

    private static func eventDateKey(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: date)
    }

    private static func dateParts(from key: String) -> (year: String?, month: String?, day: String?) {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return (nil, nil, nil) }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    private func int(_ stmt: OpaquePointer, _ idx: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, idx))
    }

    private func text(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }
}
