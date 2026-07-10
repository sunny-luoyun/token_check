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
    static let shared = try? DatabaseService()

    static let loadQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    internal var db: OpaquePointer?

    init() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path

        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, db != nil else {
            throw DatabaseError.cannotOpen(path)
        }
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
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
            SELECT COALESCE(json_extract(model, '$.providerID'), 'opencode') AS provider_id,
                   json_extract(model, '$.id') AS model_id,
                   CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END AS variant,
                   COUNT(*) AS sessions,
                   COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_reasoning), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COALESCE(SUM(cost), 0)
            FROM session
            GROUP BY provider_id, model_id, variant
            ORDER BY SUM(tokens_input) DESC
            """
        ) { stmt in
            let providerID = text(stmt, 0) ?? "opencode"
            let mid = text(stmt, 1) ?? "unknown"
            let variant = text(stmt, 2) ?? "default"
            let input = int(stmt, 4)
            let output = int(stmt, 5)
            return ModelUsage(
                id: "\(providerID)/\(mid)/\(variant)",
                providerID: providerID,
                modelId: mid,
                variant: variant,
                sessions: int(stmt, 3),
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: int(stmt, 6),
                cacheReadTokens: int(stmt, 7),
                totalTokens: input + output,
                cost: double(stmt, 8)
            )
        }
    }

    func fetchDailyUsage(days: Int = 30) throws -> [DailyUsage] {
        let cutoff = Date.now.timeIntervalSince1970 * 1000 - Double(days) * 86_400 * 1000
        return try readAll(
            """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
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

    func fetchDailyUsageByModel(days: Int = 30, year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> [DailyModelUsage] {
        var whereClause = ""
        var params: [Any] = []
        if let startDate, let endDate {
            let (clause, p) = buildDateRangeClause(from: startDate, to: endDate)
            whereClause = clause
            params = p
        } else if let year, let month, let day {
            whereClause = "WHERE strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ? AND strftime('%m', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ? AND strftime('%d', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?"
            params = [year, month, day]
        } else if let year, let month {
            whereClause = "WHERE strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ? AND strftime('%m', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?"
            params = [year, month]
        } else if let year {
            whereClause = "WHERE strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?"
            params = [year]
        } else {
            let cutoff = Date.now.timeIntervalSince1970 * 1000 - Double(days) * 86_400 * 1000
            whereClause = "WHERE time_created > ?"
            params = [Int64(cutoff)]
        }
        return try readAll(
            """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(json_extract(model, '$.providerID'), 'opencode') AS provider_id,
                   json_extract(model, '$.id') AS model_id,
                   CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END AS variant,
                     COALESCE(SUM(tokens_input), 0),
                     COALESCE(SUM(tokens_cache_read), 0),
                     COALESCE(SUM(tokens_output), 0),
                     COALESCE(SUM(tokens_reasoning), 0)
            FROM session
            \(whereClause)
            GROUP BY day, provider_id, model_id, variant
            ORDER BY day, model_id
            """,
            parameters: params
        ) { stmt in
            let dateStr = text(stmt, 0) ?? ""
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let date = df.date(from: dateStr) ?? .now
            let providerID = text(stmt, 1) ?? "opencode"
            let mid = text(stmt, 2) ?? "unknown"
            let variant = text(stmt, 3) ?? "default"
            return DailyModelUsage(
                id: "\(dateStr)/\(providerID)/\(mid)/\(variant)",
                date: date,
                providerID: providerID,
                modelId: mid,
                variant: variant,
                inputTokens: int(stmt, 4),
                outputTokens: int(stmt, 6),
                cacheReadTokens: int(stmt, 5),
                reasoningTokens: int(stmt, 7),
                cacheWriteTokens: 0
            )
        }
    }

    func fetchAvailablePeriods() throws -> [TimePeriod] {
        try readAll(
            """
            SELECT DISTINCT
                strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) AS year,
                strftime('%m', datetime(time_created / 1000, 'unixepoch', 'localtime')) AS month
            FROM session
            ORDER BY year DESC, month DESC
            """
        ) { stmt in
            TimePeriod(year: text(stmt, 0) ?? "", month: text(stmt, 1))
        }
    }

    func fetchAvailableDays(year: String, month: String) throws -> [String] {
        try readAll(
            """
            SELECT DISTINCT strftime('%d', datetime(time_created / 1000, 'unixepoch', 'localtime'))
            FROM session
            WHERE strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?
              AND strftime('%m', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?
            ORDER BY 1
            """,
            parameters: [year, month]
        ) { stmt in
            text(stmt, 0) ?? ""
        }
    }

    func fetchModelCostBreakdown(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, pricingRules: [ModelPricingRule] = [], referenceDate: Date = .now) throws -> [ModelCostBreakdown] {
        let pricingLookup = ModelPricingStore.lookup(from: pricingRules)
        let (whereClause, params) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        return try readAll(
            """
            SELECT COALESCE(json_extract(model, '$.providerID'), 'opencode') AS provider_id,
                   json_extract(model, '$.id') AS model_id,
                   CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END AS variant,
                   COUNT(*) AS sessions,
                     COALESCE(SUM(tokens_input), 0) AS miss,
                     COALESCE(SUM(tokens_cache_read), 0) AS hit,
                     COALESCE(SUM(tokens_output), 0) AS output,
                     COALESCE(SUM(tokens_reasoning), 0) AS reasoning
            FROM session
            \(whereClause)
            GROUP BY provider_id, model_id, variant
            ORDER BY SUM(tokens_input) DESC
            """,
            parameters: params
        ) { stmt in
            let providerID = text(stmt, 0) ?? "opencode"
            let modelId = text(stmt, 1) ?? "unknown"
            let variant = text(stmt, 2) ?? "default"
            let pricing = pricingLookup["\(providerID)/\(modelId)/\(variant)"] ?? .defaults(providerID: providerID, modelId: modelId, variant: variant)
            return ModelCostBreakdown(
                id: "\(providerID)/\(modelId)/\(variant)",
                providerID: providerID,
                modelId: modelId,
                variant: variant,
                sessions: int(stmt, 3),
                cacheMissTokens: int(stmt, 4),
                cacheHitTokens: int(stmt, 5),
                outputTokens: int(stmt, 6),
                reasoningTokens: int(stmt, 7),
                pricing: pricing,
                referenceDate: referenceDate
            )
        }
        .filter { $0.pricing.isEnabled }
    }

    func fetchCostSummary(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, pricingRules: [ModelPricingRule] = [], referenceDate: Date = .now) throws -> CostSummary {
        let (whereClause, params) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let pricingLookup = ModelPricingStore.lookup(from: pricingRules)
        let rows = try readAll(
            """
            SELECT COALESCE(json_extract(model, '$.providerID'), 'opencode') AS provider_id,
                   json_extract(model, '$.id') AS model_id,
                   CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END AS variant,
                   COALESCE(SUM(tokens_input), 0) AS miss,
                   COALESCE(SUM(tokens_cache_read), 0) AS hit,
                   COALESCE(SUM(tokens_output), 0) AS output,
                   COALESCE(SUM(tokens_reasoning), 0) AS reasoning,
                   COUNT(*) AS sessions
            FROM session
            \(whereClause)
            GROUP BY provider_id, model_id, variant
            """,
            parameters: params
        ) { stmt in
            let providerID = text(stmt, 0) ?? "opencode"
            let modelId = text(stmt, 1) ?? "unknown"
            let variant = text(stmt, 2) ?? "default"
            let pricing = pricingLookup["\(providerID)/\(modelId)/\(variant)"] ?? .defaults(providerID: providerID, modelId: modelId, variant: variant)
            let prices = pricing.price(at: referenceDate)
            let miss = int(stmt, 2)
            let hit = int(stmt, 3)
            let output = int(stmt, 4)
            let reasoning = int(stmt, 5)
            return (miss: miss, hit: hit, output: output, reasoning: reasoning, sessions: int(stmt, 6),
                    missPrice: prices.inputMiss, hitPrice: prices.cacheHit, outputPrice: prices.output, reasoningPrice: prices.reasoning)
        }
        guard !rows.isEmpty else {
            return CostSummary(totalMissTokens: 0, totalHitTokens: 0, totalOutputTokens: 0, totalReasoningTokens: 0, sessionCount: 0, missCost: 0, hitCost: 0, outputCost: 0, reasoningCost: 0)
        }
        var totalMiss = 0, totalHit = 0, totalOutput = 0, totalReasoning = 0, totalSessions = 0
        var missCost = 0.0, hitCost = 0.0, outputCost = 0.0, reasoningCost = 0.0
        for row in rows {
            totalMiss += row.miss
            totalHit += row.hit
            totalOutput += row.output
            totalReasoning += row.reasoning
            totalSessions += row.sessions
            missCost += Double(row.miss) / 1_000_000 * row.missPrice
            hitCost += Double(row.hit) / 1_000_000 * row.hitPrice
            outputCost += Double(row.output) / 1_000_000 * row.outputPrice
            reasoningCost += Double(row.reasoning) / 1_000_000 * row.reasoningPrice
        }
        return CostSummary(totalMissTokens: totalMiss, totalHitTokens: totalHit, totalOutputTokens: totalOutput, totalReasoningTokens: totalReasoning, sessionCount: totalSessions, missCost: missCost, hitCost: hitCost, outputCost: outputCost, reasoningCost: reasoningCost)
    }

    func fetchSessions(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, limit: Int = 100, offset: Int = 0) throws -> [Session] {
        let (whereClause, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        return try readAll(
            """
            SELECT id, slug, title,
                   tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write,
                   cost, model, time_created,
                   json_extract(metadata, '$.project') AS project
            FROM session
            \(whereClause)
            ORDER BY time_created DESC
            LIMIT ? OFFSET ?
            """,
            parameters: whereParams + [Int64(limit), Int64(offset)]
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
                providerID: modelDict?["providerID"] as? String ?? "opencode",
                modelId: modelDict?["id"] as? String ?? "unknown",
                modelVariant: { let v = modelDict?["variant"] as? String ?? "default"; return v == "max" ? "default" : v }(),
                timeCreated: Date(timeIntervalSince1970: TimeInterval(int64(stmt, 10)) / 1000),
                project: text(stmt, 11)
            )
        }
    }

    // MARK: - Agent / Project / Efficiency Stats

    func fetchAgentUsage(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> [AgentUsage] {
        let (whereClause, params) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        return try readAll(
            """
            SELECT COALESCE(NULLIF(agent, ''), 'unknown'),
                   COUNT(*),
                   COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_reasoning), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write), 0),
                   COALESCE(SUM(cost), 0)
            FROM session
            \(whereClause)
            GROUP BY agent
            ORDER BY COUNT(*) DESC
            """,
            parameters: params
        ) { stmt in
            AgentUsage(
                agentName: text(stmt, 0) ?? "unknown",
                sessions: int(stmt, 1),
                inputTokens: int(stmt, 2),
                outputTokens: int(stmt, 3),
                reasoningTokens: int(stmt, 4),
                cacheReadTokens: int(stmt, 5),
                totalTokens: int(stmt, 6),
                cost: double(stmt, 7)
            )
        }
    }

    func fetchProjectUsage(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> [ProjectUsage] {
        let (rawWhere, params) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = rawWhere.isEmpty ? "" : rawWhere.replacingOccurrences(of: "time_created", with: "s.time_created")
        return try readAll(
            """
            SELECT p.id,
                   p.name,
                   p.worktree,
                   COUNT(*),
                   COALESCE(SUM(s.tokens_input), 0),
                   COALESCE(SUM(s.tokens_output), 0),
                   COALESCE(SUM(s.tokens_reasoning), 0),
                   COALESCE(SUM(s.tokens_cache_read), 0),
                   COALESCE(SUM(s.tokens_input + s.tokens_output + s.tokens_reasoning + s.tokens_cache_read + s.tokens_cache_write), 0),
                   COALESCE(SUM(s.cost), 0)
            FROM session s
            LEFT JOIN project p ON s.project_id = p.id
            \(whereClause)
            GROUP BY p.id
            ORDER BY COUNT(*) DESC
            """,
            parameters: params
        ) { stmt in
            ProjectUsage(
                projectId: text(stmt, 0) ?? "unknown",
                projectName: text(stmt, 1) ?? "",
                worktree: text(stmt, 2) ?? "/",
                sessions: int(stmt, 3),
                inputTokens: int(stmt, 4),
                outputTokens: int(stmt, 5),
                reasoningTokens: int(stmt, 6),
                cacheReadTokens: int(stmt, 7),
                totalTokens: int(stmt, 8),
                cost: double(stmt, 9)
            )
        }
    }

    func fetchEfficiencySummary(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> ProductivitySummary {
        let (whereClause, params) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        return try readOne(
            """
            SELECT COALESCE(SUM(summary_additions), 0),
                   COALESCE(SUM(summary_deletions), 0),
                   COALESCE(SUM(summary_files), 0),
                   COUNT(*),
                   COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write), 0)
            FROM session
            \(whereClause)
            """,
            parameters: params
        ) { stmt in
            ProductivitySummary(
                totalAdditions: int(stmt, 0),
                totalDeletions: int(stmt, 1),
                totalFiles: int(stmt, 2),
                sessionsWithChanges: int(stmt, 3),
                totalTokens: int(stmt, 4)
            )
        }
    }

    func fetchEfficiencyDetail(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, limit: Int = 100, offset: Int = 0) throws -> [SessionEfficiency] {
        let (rawWhere, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = rawWhere.isEmpty ? "" : rawWhere.replacingOccurrences(of: "time_created", with: "s.time_created")
        let fullWhere = whereClause.isEmpty
            ? "WHERE (COALESCE(s.summary_additions, 0) > 0 OR COALESCE(s.summary_deletions, 0) > 0)"
            : whereClause + " AND (COALESCE(s.summary_additions, 0) > 0 OR COALESCE(s.summary_deletions, 0) > 0)"
        return try readAll(
            """
            SELECT s.id,
                   COALESCE(NULLIF(s.title, ''), s.slug, '(无标题)'),
                   COALESCE(json_extract(s.model, '$.providerID'), 'opencode'),
                   json_extract(s.model, '$.id'),
                   COALESCE(NULLIF(s.agent, ''), 'unknown'),
                   COALESCE(s.summary_additions, 0),
                   COALESCE(s.summary_deletions, 0),
                   COALESCE(s.summary_files, 0),
                   COALESCE(s.tokens_input + s.tokens_output + s.tokens_reasoning + s.tokens_cache_read + s.tokens_cache_write, 0)
            FROM session s
            \(fullWhere)
            ORDER BY s.time_created DESC
            LIMIT ? OFFSET ?
            """,
            parameters: whereParams + [Int64(limit), Int64(offset)]
        ) { stmt in
            SessionEfficiency(
                id: text(stmt, 0) ?? "",
                title: text(stmt, 1) ?? "(无标题)",
                providerID: text(stmt, 2) ?? "opencode",
                modelId: text(stmt, 3) ?? "unknown",
                agent: text(stmt, 4) ?? "unknown",
                additions: int(stmt, 5),
                deletions: int(stmt, 6),
                files: int(stmt, 7),
                totalTokens: int(stmt, 8)
            )
        }
    }

    // MARK: - Time Filter Helpers

    private func buildTimeClause(year: String?, month: String?, day: String?, from startDate: Date?, to endDate: Date?) -> (clause: String, params: [Any]) {
        if let startDate, let endDate {
            return buildDateRangeClause(from: startDate, to: endDate)
        }
        var clauses: [String] = []
        var params: [Any] = []
        if let year {
            clauses.append("strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?")
            params.append(year)
        }
        if let month {
            clauses.append("strftime('%m', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?")
            params.append(month)
        }
        if let day {
            clauses.append("strftime('%d', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?")
            params.append(day)
        }
        if clauses.isEmpty { return ("", []) }
        return ("WHERE " + clauses.joined(separator: " AND "), params)
    }

    private func buildDateRangeClause(from startDate: Date, to endDate: Date) -> (clause: String, params: [Any]) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: startDate)
        guard let endOfNextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate)) else {
            return ("", [])
        }
        return (
            clause: "WHERE time_created >= ? AND time_created < ?",
            params: [
                Int64(startOfDay.timeIntervalSince1970 * 1000),
                Int64(endOfNextDay.timeIntervalSince1970 * 1000)
            ]
        )
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
