import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case cannotOpen(String)
    case prepareError(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path):
            return "无法打开数据库，请确认 opencode 已安装并至少使用过一次\n路径: \(path)"
        case .prepareError(let msg):
            return "数据库查询错误: \(msg)"
        case .noData:
            return "暂无数据"
        }
    }
}

final class DatabaseService {
    private var db: OpaquePointer?

    init() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path

        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, db != nil else {
            throw DatabaseError.cannotOpen(path)
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        sqlite3_close(db)
    }

    func fetchTokenSummary() throws -> TokenSummary {
        try readOne(
            """
            SELECT COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_reasoning), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COALESCE(cost, 0),
                   COUNT(*)
            FROM session
            """
        ) { stmt in
            TokenSummary(
                totalInput: int(stmt, 0),
                totalOutput: int(stmt, 1),
                totalReasoning: int(stmt, 2),
                totalCacheRead: int(stmt, 3),
                totalCost: double(stmt, 4),
                sessionCount: int(stmt, 5)
            )
        }
    }

    func fetchModelUsage() throws -> [ModelUsage] {
        try readAll(
            """
            SELECT json_extract(model, '$.id') AS model_id,
                   json_extract(model, '$.variant') AS variant,
                   COUNT(*) AS sessions,
                   COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_reasoning), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COALESCE(SUM(cost), 0)
            FROM session
            GROUP BY model_id, variant
            ORDER BY SUM(tokens_input) DESC
            """
        ) { stmt in
            let mid = text(stmt, 0) ?? "unknown"
            let variant = text(stmt, 1) ?? "default"
            let input = int(stmt, 3)
            let output = int(stmt, 4)
            return ModelUsage(
                id: "\(mid)/\(variant)",
                modelId: mid,
                variant: variant,
                sessions: int(stmt, 2),
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: int(stmt, 5),
                cacheReadTokens: int(stmt, 6),
                totalTokens: input + output,
                cost: double(stmt, 7)
            )
        }
    }

    func fetchDailyUsage(days: Int = 30) throws -> [DailyUsage] {
        let cutoff = Date.now.timeIntervalSince1970 * 1000 - Double(days) * 86_400 * 1000
        return try readAll(
            """
            SELECT date(datetime(time_created / 1000, 'unixepoch')) AS day,
                   COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_input + tokens_output), 0)
            FROM session
            WHERE time_created > ?
            GROUP BY day
            ORDER BY day
            """,
            parameters: [Int64(cutoff)]
        ) { stmt in
            let dateStr = text(stmt, 0) ?? ""
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let date = df.date(from: dateStr) ?? .now
            return DailyUsage(
                id: dateStr,
                date: date,
                totalTokens: int(stmt, 3),
                inputTokens: int(stmt, 1),
                outputTokens: int(stmt, 2)
            )
        }
    }

    func fetchAvailablePeriods() throws -> [TimePeriod] {
        try readAll(
            """
            SELECT DISTINCT
                strftime('%Y', datetime(time_created / 1000, 'unixepoch')) AS year,
                strftime('%m', datetime(time_created / 1000, 'unixepoch')) AS month
            FROM session
            ORDER BY year DESC, month DESC
            """
        ) { stmt in
            TimePeriod(year: text(stmt, 0) ?? "", month: text(stmt, 1))
        }
    }

    func fetchModelCostBreakdown(year: String? = nil, month: String? = nil) throws -> [ModelCostBreakdown] {
        try readAll(
            """
            SELECT json_extract(model, '$.id') AS model_id,
                   json_extract(model, '$.variant') AS variant,
                   COUNT(*) AS sessions,
                   COALESCE(SUM(MAX(tokens_input - tokens_cache_read, 0)), 0) AS miss,
                   COALESCE(SUM(tokens_cache_read), 0) AS hit,
                   COALESCE(SUM(tokens_output), 0) AS output,
                   COALESCE(SUM(tokens_reasoning), 0) AS reasoning
            FROM session
            \(timeWhereClause(year: year, month: month))
            GROUP BY model_id, variant
            ORDER BY SUM(tokens_input) DESC
            """,
            parameters: timeParams(year: year, month: month)
        ) { stmt in
            ModelCostBreakdown(
                id: "\(text(stmt, 0) ?? "unknown")/\(text(stmt, 1) ?? "default")",
                modelId: text(stmt, 0) ?? "unknown",
                variant: text(stmt, 1) ?? "default",
                sessions: int(stmt, 2),
                cacheMissTokens: int(stmt, 3),
                cacheHitTokens: int(stmt, 4),
                outputTokens: int(stmt, 5),
                reasoningTokens: int(stmt, 6)
            )
        }
    }

    func fetchCostSummary(year: String? = nil, month: String? = nil) throws -> CostSummary {
        try readOne(
            """
            SELECT COALESCE(SUM(MAX(tokens_input - tokens_cache_read, 0)), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_reasoning), 0),
                   COUNT(*)
            FROM session
            \(timeWhereClause(year: year, month: month))
            """,
            parameters: timeParams(year: year, month: month)
        ) { stmt in
            CostSummary(
                totalMissTokens: int(stmt, 0),
                totalHitTokens: int(stmt, 1),
                totalOutputTokens: int(stmt, 2),
                totalReasoningTokens: int(stmt, 3),
                sessionCount: int(stmt, 4)
            )
        }
    }

    func fetchSessions(year: String? = nil, month: String? = nil, limit: Int = 100, offset: Int = 0) throws -> [Session] {
        try readAll(
            """
            SELECT id, slug, title,
                   tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write,
                   cost, model, time_created,
                   json_extract(metadata, '$.project') AS project
            FROM session
            \(timeWhereClause(year: year, month: month))
            ORDER BY time_created DESC
            LIMIT ? OFFSET ?
            """,
            parameters: timeParams(year: year, month: month) + [Int64(limit), Int64(offset)]
        ) { stmt in
            let modelJSON = text(stmt, 9) ?? "{}"
            let modelData = modelJSON.data(using: .utf8)
            let modelDict = try? JSONSerialization.jsonObject(with: modelData ?? Data()) as? [String: Any]
            return Session(
                id: text(stmt, 0) ?? "",
                slug: text(stmt, 1),
                title: text(stmt, 2),
                tokensInput: int(stmt, 3),
                tokensOutput: int(stmt, 4),
                tokensReasoning: int(stmt, 5),
                tokensCacheRead: int(stmt, 6),
                tokensCacheWrite: int(stmt, 7),
                cost: double(stmt, 8),
                modelId: modelDict?["id"] as? String ?? "unknown",
                modelVariant: modelDict?["variant"] as? String ?? "default",
                timeCreated: Date(timeIntervalSince1970: TimeInterval(int64(stmt, 10)) / 1000),
                project: text(stmt, 11)
            )
        }
    }

    // MARK: - Time Filter Helpers

    private func timeWhereClause(year: String?, month: String?) -> String {
        var clauses: [String] = []
        if year != nil {
            clauses.append("strftime('%Y', datetime(time_created / 1000, 'unixepoch')) = ?")
        }
        if month != nil {
            clauses.append("strftime('%m', datetime(time_created / 1000, 'unixepoch')) = ?")
        }
        if clauses.isEmpty { return "" }
        return "WHERE " + clauses.joined(separator: " AND ")
    }

    private func timeParams(year: String?, month: String?) -> [Any] {
        var params: [Any] = []
        if let year { params.append(year) }
        if let month { params.append(month) }
        return params
    }

    // MARK: - Helpers

    private func readOne<T>(_ sql: String, parameters: [Any] = [], parse: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        try bind(stmt!, parameters)

        guard sqlite3_step(stmt!) == SQLITE_ROW else {
            throw DatabaseError.noData
        }
        return try parse(stmt!)
    }

    private func readAll<T>(_ sql: String, parameters: [Any] = [], parse: (OpaquePointer) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        try bind(stmt!, parameters)

        var results: [T] = []
        while sqlite3_step(stmt!) == SQLITE_ROW {
            try results.append(parse(stmt!))
        }
        return results
    }

    private func bind(_ stmt: OpaquePointer, _ parameters: [Any]) throws {
        for (i, param) in parameters.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let val as Int:    sqlite3_bind_int64(stmt, idx, Int64(val))
            case let val as Int64:  sqlite3_bind_int64(stmt, idx, val)
            case let val as Double: sqlite3_bind_double(stmt, idx, val)
            case let val as String: sqlite3_bind_text(stmt, idx, (val as NSString).utf8String, -1, nil)
            default: break
            }
        }
    }

    private func int(_ stmt: OpaquePointer, _ idx: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, idx))
    }

    private func int64(_ stmt: OpaquePointer, _ idx: Int32) -> Int64 {
        sqlite3_column_int64(stmt, idx)
    }

    private func double(_ stmt: OpaquePointer, _ idx: Int32) -> Double {
        sqlite3_column_double(stmt, idx)
    }

    private func text(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }
}
