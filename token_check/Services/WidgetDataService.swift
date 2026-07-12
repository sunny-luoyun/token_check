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
    let todayCost: Double
    let subscriptionRemaining: Double?
    let subscriptionBudget: Double?
    let subscriptionUsed: Double?
    let subscriptionEnabled: Bool

    init(
        totalTokens: Int, inputTokens: Int, outputTokens: Int,
        cacheReadTokens: Int, reasoningTokens: Int, cacheWriteTokens: Int,
        sessionCount: Int, messageCount: Int, projectCount: Int,
        additions: Int, deletions: Int, files: Int,
        dailyTokens: [DayTokenData], todayCost: Double,
        subscriptionRemaining: Double? = nil,
        subscriptionBudget: Double? = nil,
        subscriptionUsed: Double? = nil,
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
        self.todayCost = todayCost
        self.subscriptionRemaining = subscriptionRemaining
        self.subscriptionBudget = subscriptionBudget
        self.subscriptionUsed = subscriptionUsed
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

    func fetchTodayUsage() -> TodayUsage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        defer { self.logger.debug("fetchTodayUsage SQL: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms") }

        let todayStart = todayStartMilliseconds()
        let sevenDaysAgo = todayStart - 6 * 86_400 * 1000

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = df.string(from: Date())

        let todayFromEvents = TokenDeltaTracker.shared.dailyConsumption[todayKey]
        let todayModelEvents = TokenDeltaTracker.shared.dailyModelConsumption[todayKey] ?? [:]
        let sessionRow = fetchTodayRow(db, todayStart)

        let input: Int
        let output: Int
        let cacheRead: Int
        let reasoning: Int
        let cacheWrite: Int
        let sessionCount: Int

        if let events = todayFromEvents {
            input = events.tokensInput
            output = events.tokensOutput
            cacheRead = events.tokensCacheRead
            reasoning = events.tokensReasoning
            cacheWrite = events.tokensCacheWrite
            sessionCount = sessionRow?.sessions ?? 0
        } else if let row = sessionRow {
            input = row.input
            output = row.output
            cacheRead = row.cacheRead
            reasoning = row.reasoning
            cacheWrite = row.cacheWrite
            sessionCount = row.sessions
        } else {
            return nil
        }

        let messageCount = fetchTodayMessageCount(db, todayStart)
        let projectCount = fetchTodayProjectCount(db, todayStart)

        let todayCost = fetchTodayCost(db, todayStart)

        let dailyTokens = fillMissingDays(fetchDailyTokens(db, sevenDaysAgo) ?? [], since: sevenDaysAgo)
        let dailyCosts = fetchDailyCosts(db, cutoff: sevenDaysAgo)
        let costDf = DateFormatter()
        costDf.dateFormat = "yyyy-MM-dd"
        costDf.locale = Locale(identifier: "en_US_POSIX")
        let dailyTokensWithCost = dailyTokens.map { day in
            let key = costDf.string(from: day.date)
            var total = day.totalTokens
            if let ev = TokenDeltaTracker.shared.dailyConsumption[key] {
                total = ev.total
            }
            return DayTokenData(id: day.id, date: day.date, totalTokens: total, dailyCost: dailyCosts[key] ?? 0)
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
            additions: sessionRow?.additions ?? 0,
            deletions: sessionRow?.deletions ?? 0,
            files: sessionRow?.files ?? 0,
            dailyTokens: dailyTokensWithCost,
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

    // MARK: - 订阅计费统计

    func computeSubscriptionData() -> (used: Double, budget: Double, remaining: Double)? {
        guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
              defaults.bool(forKey: "subscriptionEnabled") else { return nil }

        let startDay = defaults.integer(forKey: "subscriptionStartDay")
        let budget = defaults.double(forKey: "subscriptionBudget")
        guard startDay >= 1 && startDay <= 31 && budget > 0 else { return nil }

        let periodStart = currentSubscriptionStartDate(startDay: startDay)
        let startMs = Int64(periodStart.timeIntervalSince1970 * 1000)

        logger.debug("订阅: startDay=\(startDay) periodStart=\(ISO8601DateFormatter().string(from: periodStart)) budget=\(budget)")

        let used = fetchOpenCodeGoCost(startDateMs: startMs)
        logger.debug("订阅已用: \(String(format: "%.2f", used)) / \(String(format: "%.0f", budget)) = \(String(format: "%.0f", used / budget * 100))%")

        return (used, budget, max(budget - used, 0))
    }

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

    private func currentSubscriptionStartDate(startDay: Int) -> Date {
        let cal = Calendar.current
        let today = Date()
        let comps = cal.dateComponents([.year, .month, .day], from: today)

        let daysThisMonth = cal.range(of: .day, in: .month, for: today)?.count ?? 28
        let clampedDay = min(startDay, daysThisMonth)

        var candidateComps = DateComponents()
        candidateComps.year = comps.year
        candidateComps.month = comps.month
        candidateComps.day = clampedDay

        guard let candidateStart = cal.date(from: candidateComps) else {
            return cal.startOfDay(for: today)
        }

        let startOfToday = cal.startOfDay(for: today)
        if startOfToday >= candidateStart {
            return candidateStart
        }
        return cal.date(byAdding: .month, value: -1, to: candidateStart) ?? candidateStart
    }

    private var hasDeveco = false

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(AppDatabase.opencodePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else { return nil }
        sqlite3_busy_timeout(db, 5000)

        hasDeveco = false
        if AppDatabase.devecoExists {
            var tmp: OpaquePointer?
            if sqlite3_open_v2(AppDatabase.devecoPath, &tmp, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
                sqlite3_exec(tmp, "PRAGMA journal_mode=DELETE", nil, nil, nil)
                sqlite3_close(tmp)
            }
            let attachSQL = "ATTACH DATABASE '\(AppDatabase.devecoPath)' AS deveco"
            hasDeveco = (sqlite3_exec(db, attachSQL, nil, nil, nil) == SQLITE_OK)
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

    private func int(_ stmt: OpaquePointer, _ idx: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, idx))
    }

    private func text(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }
}
