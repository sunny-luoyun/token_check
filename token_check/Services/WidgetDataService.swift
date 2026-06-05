import Foundation
import SQLite3

struct DayTokenData: Identifiable {
    let id: String
    let date: Date
    let totalTokens: Int
}

struct TodayUsage {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let sessionCount: Int
    let dailyTokens: [DayTokenData]
}

final class WidgetDataService {
    func fetchTodayUsage() -> TodayUsage? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }

        let todayStart = todayStartMilliseconds()
        let sevenDaysAgo = todayStart - 6 * 86_400 * 1000

        guard let todayRow = fetchTodayRow(db, todayStart) else { return nil }
        let dailyTokens = fetchDailyTokens(db, sevenDaysAgo) ?? []

        return TodayUsage(
            totalTokens: todayRow.input + todayRow.output,
            inputTokens: todayRow.input,
            outputTokens: todayRow.output,
            sessionCount: todayRow.sessions,
            dailyTokens: dailyTokens
        )
    }

    private func fetchTodayRow(_ db: OpaquePointer, _ cutoff: Int64) -> (input: Int, output: Int, sessions: Int)? {
        let sql = """
            SELECT COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
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
        return (int(stmt, 0), int(stmt, 1), int(stmt, 2))
    }

    private func fetchDailyTokens(_ db: OpaquePointer, _ cutoff: Int64) -> [DayTokenData]? {
        let sql = """
            SELECT date(datetime(time_created / 1000, 'unixepoch')) AS day,
                   COALESCE(SUM(tokens_input + tokens_output), 0) AS total
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
}
