import Foundation
import SQLite3

struct DayTokenData: Identifiable, Codable {
    let id: String
    let date: Date
    let totalTokens: Int
}

struct TodayUsage: Codable {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let sessionCount: Int
    let dailyTokens: [DayTokenData]
    let todayCost: Double
}

private struct TodayModelUsage {
    let modelId: String
    let variant: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int

    var pricingKey: String {
        "\(modelId)/\(variant)"
    }
}

final class WidgetDataService {
    func fetchTodayUsage() -> TodayUsage? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }

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
        let sessionCount: Int

        if let events = todayFromEvents {
            input = events.tokensInput
            output = events.tokensOutput
            cacheRead = events.tokensCacheRead
            sessionCount = sessionRow?.sessions ?? 0
        } else if let row = sessionRow {
            input = row.input
            output = row.output
            cacheRead = row.cacheRead
            sessionCount = row.sessions
        } else {
            return nil
        }

        let pricingRules = ModelPricingStore.lookup(from: ModelPricingStore.load())
        let todayCost: Double
        if !todayModelEvents.isEmpty {
            todayCost = calculateTodayCost(from: todayModelEvents, pricingRules: pricingRules)
        } else {
            let modelUsage = fetchTodayModelUsage(db, todayStart)
            todayCost = modelUsage.isEmpty ? 0 : calculateTodayCost(modelUsage, pricingRules: pricingRules)
        }

        let dailyTokens = fillMissingDays(fetchDailyTokens(db, sevenDaysAgo) ?? [], since: sevenDaysAgo)

        return TodayUsage(
            totalTokens: input + output + cacheRead,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            sessionCount: sessionCount,
            dailyTokens: dailyTokens,
            todayCost: todayCost
        )
    }

    private func calculateTodayCost(from modelConsumption: [String: TokenData], pricingRules: [String: ModelPricingRule]) -> Double {
        modelConsumption.reduce(0) { total, item in
            let parts = item.key.split(separator: "/")
            let modelId = String(parts[0])
            let variant = parts.count > 1 ? String(parts[1]) : "default"
            let pricing = pricingRules[item.key] ?? .defaults(modelId: modelId, variant: variant)
            guard pricing.isEnabled else { return total }
            return total
                + Double(item.value.tokensInput) / 1_000_000 * pricing.inputMissPricePerMillion
                + Double(item.value.tokensCacheRead) / 1_000_000 * pricing.cacheHitPricePerMillion
                + Double(item.value.tokensOutput) / 1_000_000 * pricing.outputPricePerMillion
        }
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

    private func fetchTodayRow(_ db: OpaquePointer, _ cutoff: Int64) -> (input: Int, output: Int, cacheRead: Int, sessions: Int)? {
        let sql = """
            SELECT COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COUNT(*)
            FROM session
            WHERE time_created > ?
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (int(stmt, 0), int(stmt, 1), int(stmt, 2), int(stmt, 3))
    }

    private func fetchDailyTokens(_ db: OpaquePointer, _ cutoff: Int64) -> [DayTokenData]? {
        let sql = """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(SUM(tokens_input + tokens_cache_read + tokens_output), 0) AS total
            FROM session
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

    private func fetchTodayModelUsage(_ db: OpaquePointer, _ cutoff: Int64) -> [TodayModelUsage] {
        let sql = """
            SELECT json_extract(model, '$.id') AS model_id,
                   CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END AS variant,
                   COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_cache_read), 0)
            FROM session
            WHERE time_created > ?
            GROUP BY model_id, variant
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        var usage: [TodayModelUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            usage.append(
                TodayModelUsage(
                    modelId: text(stmt, 0) ?? "unknown",
                    variant: text(stmt, 1) ?? "default",
                    inputTokens: int(stmt, 2),
                    outputTokens: int(stmt, 3),
                    cacheReadTokens: int(stmt, 4)
                )
            )
        }
        return usage
    }

    private func calculateTodayCost(_ usage: [TodayModelUsage], pricingRules: [String: ModelPricingRule]) -> Double {
        usage.reduce(0) { total, item in
            let pricing = pricingRules[item.pricingKey] ?? .defaults(modelId: item.modelId, variant: item.variant)
            guard pricing.isEnabled else { return total }
            return total
                + Double(item.inputTokens) / 1_000_000 * pricing.inputMissPricePerMillion
                + Double(item.cacheReadTokens) / 1_000_000 * pricing.cacheHitPricePerMillion
                + Double(item.outputTokens) / 1_000_000 * pricing.outputPricePerMillion
        }
    }

    private func openDB() -> OpaquePointer? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else { return nil }
        sqlite3_busy_timeout(db, 5000)
        return db
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
