import Foundation
import OSLog
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
    private var hasDeveco = false

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "db-service")

    init() throws {
        let rc = sqlite3_open_v2(AppDatabase.opencodePath, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, db != nil else {
            throw DatabaseError.cannotOpen(AppDatabase.opencodePath)
        }
        sqlite3_busy_timeout(db, 5000)

        let devecoExists = AppDatabase.devecoExists
        if devecoExists {
            let attachSQL = "ATTACH DATABASE '\(AppDatabase.devecoPath)' AS deveco"
            let rc2 = sqlite3_exec(db, attachSQL, nil, nil, nil)
            hasDeveco = (rc2 == SQLITE_OK)
            if !hasDeveco {
                logger.error("ATTACH deveco.db 失败: \(String(cString: sqlite3_errmsg(self.db)))")
            }
        }
    }

    private let sessionCols = "id, project_id, parent_id, slug, directory, title, version, share_url, summary_additions, summary_deletions, summary_files, summary_diffs, revert, permission, time_created, time_updated, time_compacting, time_archived, workspace_id, path, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, metadata"

    private var sessionSource: String {
        hasDeveco
            ? "(SELECT \(sessionCols) FROM main.session UNION ALL SELECT \(sessionCols) FROM deveco.session) AS session"
            : "session"
    }

    private var sessionSourceAlias: String {
        hasDeveco
            ? "(SELECT \(sessionCols) FROM main.session UNION ALL SELECT \(sessionCols) FROM deveco.session) AS s"
            : "session s"
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
            FROM \(sessionSource)
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
            FROM \(sessionSource)
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
            FROM \(sessionSource)
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
        // 事件时间口径优先：tracker 的按模型日消耗
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        var eventMap: [String: [String: DailyModelUsage]] = [:] // dateKey -> modelKey -> usage
        for (dateKey, models) in TokenDeltaTracker.shared.dailyModelConsumption where keys.contains(dateKey) {
            for (modelKey, tokens) in models {
                let parts = modelKey.split(separator: "/")
                let providerID = String(parts[0])
                let modelId = parts.count > 1 ? String(parts[1]) : "unknown"
                let variant = parts.count > 2 ? String(parts[2]) : "default"
                eventMap[dateKey, default: [:]][modelKey] = DailyModelUsage(
                    id: "\(dateKey)/\(modelKey)",
                    date: Self.dateFromKey(dateKey),
                    providerID: providerID,
                    modelId: modelId,
                    variant: variant,
                    inputTokens: tokens.tokensInput,
                    outputTokens: tokens.tokensOutput,
                    cacheReadTokens: tokens.tokensCacheRead,
                    reasoningTokens: tokens.tokensReasoning,
                    cacheWriteTokens: tokens.tokensCacheWrite
                )
            }
        }

        // 兜底：事件未覆盖的日期用 session 表（SQL 范围沿用 buildTimeClause，兼容 year/month/day 与 from/to 两种模式）
        let (whereClause, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let sqlResult = try readAll(
            """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(json_extract(model, '$.providerID'), 'opencode') AS provider_id,
                   json_extract(model, '$.id') AS model_id,
                   CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END AS variant,
                     COALESCE(SUM(tokens_input), 0),
                     COALESCE(SUM(tokens_cache_read), 0),
                     COALESCE(SUM(tokens_output), 0),
                     COALESCE(SUM(tokens_reasoning), 0)
            FROM \(sessionSource)
            \(whereClause)
            GROUP BY day, provider_id, model_id, variant
            ORDER BY day, model_id
            """,
            parameters: whereParams
        ) { stmt in
            let dateStr = text(stmt, 0) ?? ""
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let date = df.date(from: dateStr) ?? .now
            let providerID = text(stmt, 1) ?? "opencode"
            let mid = text(stmt, 2) ?? "unknown"
            let variant = text(stmt, 3) ?? "default"
            let modelKey = "\(providerID)/\(mid)/\(variant)"
            return (dateStr, modelKey, DailyModelUsage(
                id: "\(dateStr)/\(modelKey)",
                date: date,
                providerID: providerID,
                modelId: mid,
                variant: variant,
                inputTokens: int(stmt, 4),
                outputTokens: int(stmt, 6),
                cacheReadTokens: int(stmt, 5),
                reasoningTokens: int(stmt, 7),
                cacheWriteTokens: 0
            ))
        }
        for (dateStr, modelKey, usage) in sqlResult where !covered.contains(dateStr) {
            eventMap[dateStr, default: [:]][modelKey] = usage
        }

        var result: [DailyModelUsage] = []
        for (_, models) in eventMap {
            for usage in models.values {
                result.append(usage)
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private static func dateFromKey(_ key: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: key) ?? .now
    }

    func fetchAvailablePeriods() throws -> [TimePeriod] {
        var periods: [TimePeriod] = []
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        for key in covered {
            let parts = key.split(separator: "-")
            guard parts.count == 3 else { continue }
            periods.append(TimePeriod(year: String(parts[0]), month: String(parts[1])))
        }
        let sqlPeriods = try readAll(
            """
            SELECT DISTINCT
                strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) AS year,
                strftime('%m', datetime(time_created / 1000, 'unixepoch', 'localtime')) AS month
            FROM \(sessionSource)
            ORDER BY year DESC, month DESC
            """
        ) { stmt in
            TimePeriod(year: text(stmt, 0) ?? "", month: text(stmt, 1))
        }
        let combined = Dictionary((periods + sqlPeriods).map { ("\($0.year)/\($0.month ?? "")", $0) }) { _, new in new }
        return combined.values.sorted { ($0.year, $0.month ?? "") > ($1.year, $1.month ?? "") }
    }

    func fetchAvailableDays(year: String, month: String) throws -> [String] {
        var days: Set<String> = []
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let prefix = "\(year)-\(month)"
        for key in covered where key.hasPrefix(prefix) {
            days.insert(String(key.suffix(2)))
        }
        let sqlDays = try readAll(
            """
            SELECT DISTINCT strftime('%d', datetime(time_created / 1000, 'unixepoch', 'localtime'))
            FROM \(sessionSource)
            WHERE strftime('%Y', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?
              AND strftime('%m', datetime(time_created / 1000, 'unixepoch', 'localtime')) = ?
            ORDER BY 1
            """,
            parameters: [year, month]
        ) { stmt in
            text(stmt, 0) ?? ""
        }
        days.formUnion(sqlDays)
        return days.sorted()
    }

    func fetchModelCostBreakdown(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, pricingRules: [ModelPricingRule] = [], referenceDate: Date = .now) throws -> [ModelCostBreakdown] {
        let pricingLookup = ModelPricingStore.lookup(from: pricingRules)
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)

        // 事件时间口径的会话数：按活跃会话 id 从 session 表精确计数（按模型归一化分组）
        var sessionCounts: [String: Int] = [:]
        if !coveredInRange.isEmpty {
            let activeIDs = Array(TokenDeltaTracker.shared.sessionDelta(in: coveredInRange).keys)
            if !activeIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: activeIDs.count).joined(separator: ",")
                let rows = try readAll(
                    """
                    SELECT COALESCE(json_extract(model, '$.providerID'), 'opencode'),
                           json_extract(model, '$.id'),
                           CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END,
                           COUNT(*)
                    FROM \(sessionSource)
                    WHERE id IN (\(placeholders))
                    GROUP BY 1, 2, 3
                    """,
                    parameters: activeIDs
                ) { stmt in
                    (providerID: text(stmt, 0) ?? "opencode", modelId: text(stmt, 1) ?? "unknown", variant: text(stmt, 2) ?? "default", count: int(stmt, 3))
                }
                for row in rows {
                    sessionCounts["\(row.providerID)/\(row.modelId)/\(row.variant)"] = row.count
                }
            }
        }

        // 事件时间口径：按模型增量
        var breakdownMap: [String: ModelCostBreakdown] = [:]
        for (modelKey, tokens) in TokenDeltaTracker.shared.dailyModelConsumption
            .filter({ keys.contains($0.key) })
            .flatMap({ $0.value }) {
            let parts = modelKey.split(separator: "/")
            let providerID = String(parts[0])
            let modelId = parts.count > 1 ? String(parts[1]) : "unknown"
            let variant = parts.count > 2 ? String(parts[2]) : "default"
            let pricing = pricingLookup[modelKey] ?? .defaults(providerID: providerID, modelId: modelId, variant: variant)
            let existing = breakdownMap[modelKey]
            breakdownMap[modelKey] = ModelCostBreakdown(
                id: modelKey,
                providerID: providerID,
                modelId: modelId,
                variant: variant,
                // 会话数是整个时间段去重后的活跃会话总数，循环内不累加（首次置值，后续保持）
                sessions: existing?.sessions ?? (sessionCounts[modelKey] ?? 0),
                cacheMissTokens: (existing?.cacheMissTokens ?? 0) + tokens.tokensInput,
                cacheHitTokens: (existing?.cacheHitTokens ?? 0) + tokens.tokensCacheRead,
                outputTokens: (existing?.outputTokens ?? 0) + tokens.tokensOutput,
                reasoningTokens: (existing?.reasoningTokens ?? 0) + tokens.tokensReasoning,
                pricing: pricing,
                referenceDate: referenceDate
            )
        }

        // 兜底：事件未覆盖日期用 session 表（排除事件覆盖日期，避免重复计数）
        let (exclusion, exclusionParams) = buildExclusionClause(coveredInRange: coveredInRange)
        let (rawWhere, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = appendingExclusion(rawWhere, exclusion: exclusion)
        let sqlBreakdown = try readAll(
            """
            SELECT COALESCE(json_extract(model, '$.providerID'), 'opencode') AS provider_id,
                   json_extract(model, '$.id') AS model_id,
                   CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END AS variant,
                   COUNT(*) AS sessions,
                     COALESCE(SUM(tokens_input), 0) AS miss,
                     COALESCE(SUM(tokens_cache_read), 0) AS hit,
                     COALESCE(SUM(tokens_output), 0) AS output,
                       COALESCE(SUM(tokens_reasoning), 0) AS reasoning
            FROM \(sessionSource)
            \(whereClause)
            GROUP BY provider_id, model_id, variant
            ORDER BY SUM(tokens_input) DESC
            """,
            parameters: whereParams + exclusionParams
        ) { stmt in
            let providerID = text(stmt, 0) ?? "opencode"
            let modelId = text(stmt, 1) ?? "unknown"
            let variant = text(stmt, 2) ?? "default"
            return (providerID, modelId, variant, int(stmt, 3), int(stmt, 4), int(stmt, 5), int(stmt, 6), int(stmt, 7))
        }
        // 事件与 SQL 覆盖互补日期，同 key 合并累加；事件未出现的 key 直接填入
        for (providerID, modelId, variant, sessions, miss, hit, output, reasoning) in sqlBreakdown {
            let modelKey = "\(providerID)/\(modelId)/\(variant)"
            let pricing = pricingLookup[modelKey] ?? .defaults(providerID: providerID, modelId: modelId, variant: variant)
            if let existing = breakdownMap[modelKey] {
                breakdownMap[modelKey] = ModelCostBreakdown(
                    id: modelKey,
                    providerID: providerID,
                    modelId: modelId,
                    variant: variant,
                    sessions: existing.sessions + sessions,
                    cacheMissTokens: existing.cacheMissTokens + miss,
                    cacheHitTokens: existing.cacheHitTokens + hit,
                    outputTokens: existing.outputTokens + output,
                    reasoningTokens: existing.reasoningTokens + reasoning,
                    pricing: pricing,
                    referenceDate: referenceDate
                )
            } else {
                breakdownMap[modelKey] = ModelCostBreakdown(
                    id: modelKey,
                    providerID: providerID,
                    modelId: modelId,
                    variant: variant,
                    sessions: sessions,
                    cacheMissTokens: miss,
                    cacheHitTokens: hit,
                    outputTokens: output,
                    reasoningTokens: reasoning,
                    pricing: pricing,
                    referenceDate: referenceDate
                )
            }
        }

        return breakdownMap.values
            .filter { $0.pricing.isEnabled }
            .sorted { $0.cacheMissTokens > $1.cacheMissTokens }
    }

    func fetchCostSummary(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, pricingRules: [ModelPricingRule] = [], referenceDate: Date = .now) throws -> CostSummary {
        let breakdown = try fetchModelCostBreakdown(
            year: year, month: month, day: day,
            from: startDate, to: endDate,
            pricingRules: pricingRules,
            referenceDate: referenceDate
        )
        return CostSummary.from(breakdown: breakdown)
    }

    func fetchSessions(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, limit: Int = 100, offset: Int = 0) throws -> [Session] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)

        var result: [Session] = []
        var seenIDs: Set<String> = []
        if !coveredInRange.isEmpty {
            // 事件时间口径：时间段内有活动的会话 + 增量值
            let activeIDs = TokenDeltaTracker.shared.activeSessionIDs(in: coveredInRange)
            if !activeIDs.isEmpty {
                let deltas = TokenDeltaTracker.shared.sessionDelta(in: coveredInRange)
                let placeholders = Array(repeating: "?", count: activeIDs.count).joined(separator: ",")
                let rows = try readAll(
                    """
                    SELECT id, slug, title,
                           json_extract(model, '$.providerID'),
                           json_extract(model, '$.id'),
                           CASE WHEN json_extract(model, '$.variant') = 'max' THEN 'default' ELSE COALESCE(json_extract(model, '$.variant'), 'default') END,
                           json_extract(metadata, '$.project'),
                           time_created
                    FROM \(sessionSource)
                    WHERE id IN (\(placeholders))
                    ORDER BY time_created DESC
                    """,
                    parameters: Array(activeIDs)
                ) { stmt in
                    (id: text(stmt, 0) ?? "", slug: text(stmt, 1), title: text(stmt, 2),
                     providerID: text(stmt, 3) ?? "opencode", modelId: text(stmt, 4) ?? "unknown",
                     variant: text(stmt, 5) ?? "default", project: text(stmt, 6),
                     timeCreated: Date(timeIntervalSince1970: TimeInterval(int64(stmt, 7)) / 1000))
                }
                for row in rows {
                    let delta = deltas[row.id] ?? .zero
                    result.append(Session(
                        id: row.id,
                        slug: row.slug,
                        title: row.title,
                        tokensInput: delta.tokens.tokensInput,
                        tokensOutput: delta.tokens.tokensOutput,
                        tokensReasoning: delta.tokens.tokensReasoning,
                        tokensCacheRead: delta.tokens.tokensCacheRead,
                        tokensCacheWrite: delta.tokens.tokensCacheWrite,
                        cost: delta.cost,
                        providerID: row.providerID,
                        modelId: row.modelId,
                        modelVariant: row.variant,
                        timeCreated: row.timeCreated,
                        project: row.project
                    ))
                    seenIDs.insert(row.id)
                }
            }
        }
        // 兜底：事件未覆盖日期用 session 表（排除事件覆盖日期，避免跨天会话历史重复）
        let (exclusion, exclusionParams) = buildExclusionClause(coveredInRange: coveredInRange)
        let (rawWhere, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = appendingExclusion(rawWhere, exclusion: exclusion)
        let sqlSessions = try readAll(
            """
            SELECT id, slug, title,
                   tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write,
                   cost, model, time_created,
                   json_extract(metadata, '$.project') AS project
            FROM \(sessionSource)
            \(whereClause)
            ORDER BY time_created DESC
            """,
            parameters: whereParams + exclusionParams
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
        for s in sqlSessions where !seenIDs.contains(s.id) {
            result.append(s)
        }

        // 分页（与 SQL 兜底 ORDER BY time_created DESC 一致）
        result.sort { $0.timeCreated > $1.timeCreated }
        let start = min(offset, result.count)
        let end = min(start + limit, result.count)
        return Array(result[start..<end])
    }

    // MARK: - Agent / Project / Efficiency Stats

    func fetchAgentUsage(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> [AgentUsage] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)

        // 事件时间口径的会话数：按活跃会话 id 从 session 表按 agent 精确计数
        var sessionCounts: [String: Int] = [:]
        if !coveredInRange.isEmpty {
            let activeIDs = Array(TokenDeltaTracker.shared.sessionDelta(in: coveredInRange).keys)
            if !activeIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: activeIDs.count).joined(separator: ",")
                let rows = try readAll(
                    """
                    SELECT COALESCE(NULLIF(agent, ''), 'unknown'), COUNT(*)
                    FROM \(sessionSource)
                    WHERE id IN (\(placeholders))
                    GROUP BY 1
                    """,
                    parameters: activeIDs
                ) { stmt in
                    (agent: text(stmt, 0) ?? "unknown", count: int(stmt, 1))
                }
                for row in rows {
                    sessionCounts[row.agent] = row.count
                }
            }
        }

        var map: [String: AgentUsage] = [:]
        for (dateKey, agents) in TokenDeltaTracker.shared.agentConsumption where keys.contains(dateKey) {
            for (agent, tokens) in agents {
                let costs = TokenDeltaTracker.shared.agentCostConsumption[dateKey]?[agent] ?? 0
                let existing = map[agent]
                map[agent] = AgentUsage(
                    agentName: agent,
                    // 会话数是整个时间段去重后的活跃会话总数，循环内不累加（首次置值，后续保持）
                    sessions: existing?.sessions ?? (sessionCounts[agent] ?? 0),
                    inputTokens: (existing?.inputTokens ?? 0) + tokens.tokensInput,
                    outputTokens: (existing?.outputTokens ?? 0) + tokens.tokensOutput,
                    reasoningTokens: (existing?.reasoningTokens ?? 0) + tokens.tokensReasoning,
                    cacheReadTokens: (existing?.cacheReadTokens ?? 0) + tokens.tokensCacheRead,
                    totalTokens: (existing?.totalTokens ?? 0) + tokens.total,
                    cost: (existing?.cost ?? 0) + costs
                )
            }
        }
        // 兜底：事件未覆盖日期用 session 表（排除事件覆盖日期，避免重复计数）
        let (exclusion, exclusionParams) = buildExclusionClause(coveredInRange: coveredInRange)
        let (rawWhere, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = appendingExclusion(rawWhere, exclusion: exclusion)
        let sql = try readAll(
            """
            SELECT COALESCE(NULLIF(agent, ''), 'unknown'),
                   COUNT(*),
                   COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_reasoning), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write), 0),
                   COALESCE(SUM(cost), 0)
            FROM \(sessionSource)
            \(whereClause)
            GROUP BY agent
            ORDER BY COUNT(*) DESC
            """,
            parameters: whereParams + exclusionParams
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
        // 事件与 SQL 覆盖互补日期，同 key 合并累加；事件未出现的 agent 直接填入
        for item in sql {
            if let existing = map[item.agentName] {
                map[item.agentName] = AgentUsage(
                    agentName: item.agentName,
                    sessions: existing.sessions + item.sessions,
                    inputTokens: existing.inputTokens + item.inputTokens,
                    outputTokens: existing.outputTokens + item.outputTokens,
                    reasoningTokens: existing.reasoningTokens + item.reasoningTokens,
                    cacheReadTokens: existing.cacheReadTokens + item.cacheReadTokens,
                    totalTokens: existing.totalTokens + item.totalTokens,
                    cost: existing.cost + item.cost
                )
            } else {
                map[item.agentName] = item
            }
        }
        return map.values.sorted { $0.sessions > $1.sessions }
    }

    func fetchProjectUsage(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> [ProjectUsage] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)

        // 事件时间口径的会话数：按活跃会话 id 从 session 表按项目精确计数
        var sessionCounts: [String: Int] = [:]
        if !coveredInRange.isEmpty {
            let activeIDs = Array(TokenDeltaTracker.shared.sessionDelta(in: coveredInRange).keys)
            if !activeIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: activeIDs.count).joined(separator: ",")
                let rows = try readAll(
                    """
                    SELECT COALESCE(project_id, 'unknown'), COUNT(*)
                    FROM \(sessionSource)
                    WHERE id IN (\(placeholders))
                    GROUP BY 1
                    """,
                    parameters: activeIDs
                ) { stmt in
                    (projectId: text(stmt, 0) ?? "unknown", count: int(stmt, 1))
                }
                for row in rows {
                    sessionCounts[row.projectId] = row.count
                }
            }
        }

        var map: [String: ProjectUsage] = [:]
        for (dateKey, projects) in TokenDeltaTracker.shared.projectConsumption where keys.contains(dateKey) {
            for (projectID, tokens) in projects {
                let costs = TokenDeltaTracker.shared.projectCostConsumption[dateKey]?[projectID] ?? 0
                let existing = map[projectID]
                map[projectID] = ProjectUsage(
                    projectId: projectID,
                    projectName: existing?.projectName ?? "",
                    worktree: existing?.worktree ?? "/",
                    // 会话数是整个时间段去重后的活跃会话总数，循环内不累加（首次置值，后续保持）
                    sessions: existing?.sessions ?? (sessionCounts[projectID] ?? 0),
                    inputTokens: (existing?.inputTokens ?? 0) + tokens.tokensInput,
                    outputTokens: (existing?.outputTokens ?? 0) + tokens.tokensOutput,
                    reasoningTokens: (existing?.reasoningTokens ?? 0) + tokens.tokensReasoning,
                    cacheReadTokens: (existing?.cacheReadTokens ?? 0) + tokens.tokensCacheRead,
                    totalTokens: (existing?.totalTokens ?? 0) + tokens.total,
                    cost: (existing?.cost ?? 0) + costs
                )
            }
        }
        // 补充项目名（project 表按 id 查询）
        let ids = Array(map.keys)
        if !ids.isEmpty {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let names = try readAll(
                """
                SELECT id, COALESCE(name, ''), COALESCE(worktree, '/')
                FROM project
                WHERE id IN (\(placeholders))
                """,
                parameters: ids
            ) { stmt in
                (id: text(stmt, 0) ?? "", name: text(stmt, 1) ?? "", worktree: text(stmt, 2) ?? "/")
            }
            for row in names {
                if let item = map[row.id] {
                    map[row.id] = ProjectUsage(
                        projectId: item.projectId,
                        projectName: row.name,
                        worktree: row.worktree,
                        sessions: item.sessions,
                        inputTokens: item.inputTokens,
                        outputTokens: item.outputTokens,
                        reasoningTokens: item.reasoningTokens,
                        cacheReadTokens: item.cacheReadTokens,
                        totalTokens: item.totalTokens,
                        cost: item.cost
                    )
                }
            }
        }
        // 兜底：事件未覆盖日期用 session 表（排除事件覆盖日期，避免重复计数）
        let (exclusion, exclusionParams) = buildExclusionClause(coveredInRange: coveredInRange, alias: "s")
        let (rawWhere, params) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = rawWhere.isEmpty ? "" : rawWhere.replacingOccurrences(of: "time_created", with: "s.time_created")
        let fullWhere = appendingExclusion(whereClause, exclusion: exclusion)
        let sql = try readAll(
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
            FROM \(sessionSourceAlias)
            LEFT JOIN project p ON s.project_id = p.id
            \(fullWhere)
            GROUP BY p.id
            ORDER BY COUNT(*) DESC
            """,
            parameters: params + exclusionParams
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
        // 事件与 SQL 覆盖互补日期，同 key 合并累加；事件未出现的项目直接填入
        for item in sql {
            if let existing = map[item.projectId] {
                map[item.projectId] = ProjectUsage(
                    projectId: item.projectId,
                    projectName: item.projectName.isEmpty ? existing.projectName : item.projectName,
                    worktree: item.worktree == "/" ? existing.worktree : item.worktree,
                    sessions: existing.sessions + item.sessions,
                    inputTokens: existing.inputTokens + item.inputTokens,
                    outputTokens: existing.outputTokens + item.outputTokens,
                    reasoningTokens: existing.reasoningTokens + item.reasoningTokens,
                    cacheReadTokens: existing.cacheReadTokens + item.cacheReadTokens,
                    totalTokens: existing.totalTokens + item.totalTokens,
                    cost: existing.cost + item.cost
                )
            } else {
                map[item.projectId] = item
            }
        }
        return map.values.sorted { $0.sessions > $1.sessions }
    }

    func fetchEfficiencySummary(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> ProductivitySummary {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)

        // 事件时间口径：事件覆盖日期的增量汇总（总是执行，与 SQL 兜底合并）
        var sum = SummaryData.zero
        var sessionCount = 0
        for (dateKey, s) in TokenDeltaTracker.shared.dailySummary where keys.contains(dateKey) {
            sum += s
            if s.total > 0 { sessionCount += 1 }
        }
        var totalTokens = TokenData.zero
        for (dateKey, tokens) in TokenDeltaTracker.shared.dailyConsumption where keys.contains(dateKey) {
            totalTokens = totalTokens + tokens
        }

        // 兜底：事件未覆盖日期用 session 表（排除事件覆盖日期，避免重复计数）
        let (exclusion, exclusionParams) = buildExclusionClause(coveredInRange: coveredInRange)
        let (rawWhere, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = appendingExclusion(rawWhere, exclusion: exclusion)
        let sqlRows = try readAll(
            """
            SELECT COALESCE(SUM(summary_additions), 0),
                   COALESCE(SUM(summary_deletions), 0),
                   COALESCE(SUM(summary_files), 0),
                   COUNT(*),
                   COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write), 0)
            FROM \(sessionSource)
            \(whereClause)
            """,
            parameters: whereParams + exclusionParams
        ) { stmt in
            ProductivitySummary(
                totalAdditions: int(stmt, 0),
                totalDeletions: int(stmt, 1),
                totalFiles: int(stmt, 2),
                sessionsWithChanges: int(stmt, 3),
                totalTokens: int(stmt, 4)
            )
        }
        let sqlSummary = sqlRows.first ?? ProductivitySummary(
            totalAdditions: 0, totalDeletions: 0, totalFiles: 0, sessionsWithChanges: 0, totalTokens: 0
        )
        return ProductivitySummary(
            totalAdditions: sum.additions + sqlSummary.totalAdditions,
            totalDeletions: sum.deletions + sqlSummary.totalDeletions,
            totalFiles: sum.files + sqlSummary.totalFiles,
            sessionsWithChanges: sessionCount + sqlSummary.sessionsWithChanges,
            totalTokens: totalTokens.total + sqlSummary.totalTokens
        )
    }

    func fetchEfficiencyDetail(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, limit: Int = 100, offset: Int = 0) throws -> [SessionEfficiency] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)

        // 事件时间口径：时间段内有活动且产生变更量的会话，显示增量（总是执行，与 SQL 兜底合并）
        var result: [(timeCreated: Date, item: SessionEfficiency)] = []
        var seenIDs: Set<String> = []
        if !coveredInRange.isEmpty {
            let deltas = TokenDeltaTracker.shared.sessionDelta(in: coveredInRange)
            let activeIDs = deltas.keys.filter { deltas[$0]?.summary.total ?? 0 > 0 }
            if !activeIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: activeIDs.count).joined(separator: ",")
                let rows = try readAll(
                    """
                    SELECT s.id,
                           COALESCE(NULLIF(s.title, ''), s.slug, '(无标题)'),
                           COALESCE(json_extract(s.model, '$.providerID'), 'opencode'),
                           json_extract(s.model, '$.id'),
                           COALESCE(NULLIF(s.agent, ''), 'unknown'),
                           s.time_created
                    FROM \(sessionSourceAlias)
                    WHERE s.id IN (\(placeholders))
                    ORDER BY s.time_created DESC
                    """,
                    parameters: Array(activeIDs)
                ) { stmt in
                    (id: text(stmt, 0) ?? "", title: text(stmt, 1) ?? "(无标题)",
                     providerID: text(stmt, 2) ?? "opencode", modelId: text(stmt, 3) ?? "unknown",
                     agent: text(stmt, 4) ?? "unknown",
                     timeCreated: Date(timeIntervalSince1970: TimeInterval(int64(stmt, 5)) / 1000))
                }
                for row in rows {
                    guard let delta = deltas[row.id] else { continue }
                    result.append((row.timeCreated, SessionEfficiency(
                        id: row.id,
                        title: row.title,
                        providerID: row.providerID,
                        modelId: row.modelId,
                        agent: row.agent,
                        additions: delta.summary.additions,
                        deletions: delta.summary.deletions,
                        files: delta.summary.files,
                        totalTokens: delta.totalTokens
                    )))
                    seenIDs.insert(row.id)
                }
            }
        }
        // 兜底：事件未覆盖日期用 session 表（排除事件覆盖日期，避免重复计数）
        let (exclusion, exclusionParams) = buildExclusionClause(coveredInRange: coveredInRange, alias: "s")
        let (rawWhere, whereParams) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
        let whereClause = rawWhere.isEmpty ? "" : rawWhere.replacingOccurrences(of: "time_created", with: "s.time_created")
        let fullWhere = appendingExclusion(whereClause, exclusion: exclusion)
        let changedCond = "(COALESCE(s.summary_additions, 0) > 0 OR COALESCE(s.summary_deletions, 0) > 0)"
        let changedWhere = fullWhere.isEmpty
            ? "WHERE \(changedCond)"
            : "\(fullWhere) AND \(changedCond)"
        let sqlRows = try readAll(
            """
            SELECT s.id,
                   COALESCE(NULLIF(s.title, ''), s.slug, '(无标题)'),
                   COALESCE(json_extract(s.model, '$.providerID'), 'opencode'),
                   json_extract(s.model, '$.id'),
                   COALESCE(NULLIF(s.agent, ''), 'unknown'),
                   COALESCE(s.summary_additions, 0),
                   COALESCE(s.summary_deletions, 0),
                   COALESCE(s.summary_files, 0),
                   COALESCE(s.tokens_input + s.tokens_output + s.tokens_reasoning + s.tokens_cache_read + s.tokens_cache_write, 0),
                   s.time_created
            FROM \(sessionSourceAlias)
            \(changedWhere)
            ORDER BY s.time_created DESC
            """,
            parameters: whereParams + exclusionParams
        ) { stmt in
            (timeCreated: Date(timeIntervalSince1970: TimeInterval(int64(stmt, 9)) / 1000),
             item: SessionEfficiency(
                id: text(stmt, 0) ?? "",
                title: text(stmt, 1) ?? "(无标题)",
                providerID: text(stmt, 2) ?? "opencode",
                modelId: text(stmt, 3) ?? "unknown",
                agent: text(stmt, 4) ?? "unknown",
                additions: int(stmt, 5),
                deletions: int(stmt, 6),
                files: int(stmt, 7),
                totalTokens: int(stmt, 8)
            ))
        }
        for row in sqlRows where !seenIDs.contains(row.item.id) {
            result.append(row)
        }

        // 分页（与 SQL 兜底 ORDER BY s.time_created DESC 一致）
        result.sort { $0.timeCreated > $1.timeCreated }
        let start = min(offset, result.count)
        let end = min(start + limit, result.count)
        return Array(result[start..<end]).map { $0.item }
    }

    // MARK: - Time Filter Helpers

    /// 构建"排除事件覆盖日期"的 SQL 条件：事件与 session 兜底总是合并时，SQL 只查事件未覆盖的日期
    private func buildExclusionClause(coveredInRange: Set<String>, alias: String = "") -> (clause: String, params: [Any]) {
        guard !coveredInRange.isEmpty else { return ("", []) }
        let timeCol = alias.isEmpty ? "time_created" : "\(alias).time_created"
        let placeholders = Array(repeating: "?", count: coveredInRange.count).joined(separator: ",")
        let cond = "date(datetime(\(timeCol) / 1000, 'unixepoch', 'localtime')) NOT IN (\(placeholders))"
        return (cond, coveredInRange.sorted())
    }

    /// 将排除条件附加到既有 WHERE 子句（空条件返回原样）
    private func appendingExclusion(_ whereClause: String, exclusion: String) -> String {
        if exclusion.isEmpty { return whereClause }
        return whereClause.isEmpty ? "WHERE \(exclusion)" : "\(whereClause) AND \(exclusion)"
    }

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

    /// 将 year/month/day 或日期范围转换为日期 key 集合（yyyy-MM-dd）
    private func dateKeys(year: String?, month: String?, day: String?, from startDate: Date?, to endDate: Date?) -> Set<String> {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        var keys: Set<String> = []
        if let startDate, let endDate {
            let cal = Calendar.current
            var current = cal.startOfDay(for: startDate)
            let end = cal.startOfDay(for: endDate)
            while current <= end {
                keys.insert(df.string(from: current))
                guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
                current = next
            }
        } else {
            // 遍历事件覆盖日期，按年月日精确过滤
            let covered = TokenDeltaTracker.shared.coveredDateKeys()
            for key in covered {
                let parts = key.split(separator: "-")
                guard parts.count == 3 else { continue }
                if let year, String(parts[0]) != year { continue }
                if let month, String(parts[1]) != month { continue }
                if let day, String(parts[2]) != day { continue }
                keys.insert(key)
            }
        }
        return keys
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
