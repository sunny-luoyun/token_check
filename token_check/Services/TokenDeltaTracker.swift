import Foundation
import OSLog
import SQLite3

@propertyWrapper
struct Atomic<Value> {
    private let lock = NSLock()
    private var value: Value
    init(wrappedValue: Value) { self.value = wrappedValue }
    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class TokenDeltaTracker {
    static let shared = TokenDeltaTracker()

    @Atomic var rollbackRecord = RollbackRecord.zero
    @Atomic var sessionRollbacks: [String: RollbackRecord] = [:]
    @Atomic var modelRollbacks: [String: TokenData] = [:]
    @Atomic var dailyRollbacks: [String: RollbackRecord] = [:]
    @Atomic var dailyModelRollbacks: [String: [String: TokenData]] = [:]
    @Atomic var dailyConsumption: [String: TokenData] = [:]
    @Atomic var dailyModelConsumption: [String: [String: TokenData]] = [:]
    @Atomic var hourlyConsumption: [String: TokenData] = [:]
    @Atomic var sessionCostCache: [String: Double] = [:]
    @Atomic var sessionSummaryCache: [String: SummaryData] = [:]
    @Atomic var dailyCostConsumption: [String: Double] = [:]
    @Atomic var hourlyCostConsumption: [String: Double] = [:]
    @Atomic var modelCostConsumption: [String: [String: Double]] = [:]
    @Atomic var dailySummary: [String: SummaryData] = [:]
    @Atomic var sessionDailyDelta: [String: [String: SessionDelta]] = [:]
    @Atomic var sessionActiveDays: [String: Set<String>] = [:]
    @Atomic var dailyActiveSessions: [String: Set<String>] = [:]
    @Atomic var dailyActiveProjects: [String: Set<String>] = [:]
    @Atomic var agentConsumption: [String: [String: TokenData]] = [:]
    @Atomic var projectConsumption: [String: [String: TokenData]] = [:]
    @Atomic var agentCostConsumption: [String: [String: Double]] = [:]
    @Atomic var projectCostConsumption: [String: [String: Double]] = [:]
    @Atomic var coveredDates: Set<String> = []

    // 增量处理缓存：记录上次处理到的 event rowid 和中间状态
    @Atomic var lastProcessedRowId: Int64 = 0
    @Atomic var devecoLastProcessedRowId: Int64 = 0
    @Atomic var sessionTokenCache: [String: TokenData] = [:]
    @Atomic var sessionModelCache: [String: String] = [:]
    @Atomic var pendingRbCache: [String: SessionDelta] = [:]
    @Atomic var pendingRbModelCache: [String: String] = [:]
    @Atomic var pendingRbTimestampCache: [String: Int64] = [:]

    var hasRollbackData: Bool {
        rollbackRecord.total > 0
    }

    private static let dailyDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private init() {}

    func refresh(db: OpaquePointer) {
        // 获取当前最大 rowid
        var maxStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rowid), 0) FROM event", -1, &maxStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(maxStmt) }
        var maxRowId: Int64 = 0
        if sqlite3_step(maxStmt) == SQLITE_ROW {
            maxRowId = sqlite3_column_int64(maxStmt, 0)
        }

        if maxRowId > lastProcessedRowId {
            let startRowId = lastProcessedRowId

            // 加载缓存的 session 状态
            var sessionTokens = sessionTokenCache
            var sessionModels = sessionModelCache
            var pendingRollbacks = pendingRbCache
            var pendingRollbackModels = pendingRbModelCache
            var pendingRollbackTimestamps = pendingRbTimestampCache

            // 加载已有累计值，增量追加
            var rb = rollbackRecord
            var sRb = sessionRollbacks
            var mRb = modelRollbacks
            var dRb = dailyRollbacks
            var dMRb = dailyModelRollbacks
            var dCon = dailyConsumption
            var dMCon = dailyModelConsumption
            var hCon = hourlyConsumption
            var sessionCosts = sessionCostCache
            var sessionSummaries = sessionSummaryCache
            var dCost = dailyCostConsumption
            var hCost = hourlyCostConsumption
            var mCost = modelCostConsumption
            var dSum = dailySummary
            var sDelta = sessionDailyDelta
            var sActive = sessionActiveDays
            var dActiveS = dailyActiveSessions
            var dActiveP = dailyActiveProjects
            var aCon = agentConsumption
            var pCon = projectConsumption
            var aCost = agentCostConsumption
            var pCost = projectCostConsumption
            var covered = coveredDates

            // 只处理新增的 event
            let sql = """
                SELECT rowid, aggregate_id, type, data
                FROM event
                WHERE rowid > ?
                ORDER BY rowid
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, startRowId)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let aggregateId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                      let type = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                      type == "session.updated.1",
                      let data = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let info = json["info"] as? [String: Any],
                      let tokensDict = info["tokens"] as? [String: Any]
                else { continue }

                let tokens = TokenData(
                    tokensInput: (tokensDict["input"] as? Int) ?? 0,
                    tokensOutput: (tokensDict["output"] as? Int) ?? 0,
                    tokensReasoning: (tokensDict["reasoning"] as? Int) ?? 0,
                    tokensCacheRead: ((tokensDict["cache"] as? [String: Any])?["read"] as? Int) ?? 0,
                    tokensCacheWrite: ((tokensDict["cache"] as? [String: Any])?["write"] as? Int) ?? 0
                )
                let cost = (info["cost"] as? Double) ?? 0
                let summary = SummaryData(
                    additions: (info["summary"] as? [String: Any])?["additions"] as? Int ?? 0,
                    deletions: (info["summary"] as? [String: Any])?["deletions"] as? Int ?? 0,
                    files: (info["summary"] as? [String: Any])?["files"] as? Int ?? 0
                )

                let eventTimestamp: Int64 = {
                    if let timeObj = info["time"] as? [String: Any], let updated = timeObj["updated"] as? Int64 {
                        return updated
                    }
                    return 0
                }()

                let agent = (info["agent"] as? String) ?? "unknown"
                let projectID = (info["projectID"] as? String) ?? "unknown"

                if let modelKey = extractModelKey(from: info) {
                    sessionModels[aggregateId] = modelKey
                }

                let hasRevert = info["revert"] != nil

                let prevSessionState = sessionTokens[aggregateId]
                if !hasRevert, eventTimestamp > 0 {
                    let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(eventTimestamp) / 1000))
                    let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(eventTimestamp) / 1000))
                    let hourlyKey = "\(dateKey)/\(String(format: "%02d", hour))"

                    let tokenDelta: TokenData
                    if let prev = prevSessionState {
                        tokenDelta = TokenData(
                            tokensInput: max(0, tokens.tokensInput - prev.tokensInput),
                            tokensOutput: max(0, tokens.tokensOutput - prev.tokensOutput),
                            tokensReasoning: max(0, tokens.tokensReasoning - prev.tokensReasoning),
                            tokensCacheRead: max(0, tokens.tokensCacheRead - prev.tokensCacheRead),
                            tokensCacheWrite: max(0, tokens.tokensCacheWrite - prev.tokensCacheWrite)
                        )
                    } else {
                        tokenDelta = tokens
                    }
                    let prevCost = sessionCosts[aggregateId] ?? 0
                    let costDelta = max(0, cost - prevCost)
                    let prevSummary = sessionSummaries[aggregateId] ?? .zero
                    let summaryDelta = SummaryData(
                        additions: max(0, summary.additions - prevSummary.additions),
                        deletions: max(0, summary.deletions - prevSummary.deletions),
                        files: max(0, summary.files - prevSummary.files)
                    )
                    sessionCosts[aggregateId] = cost
                    sessionSummaries[aggregateId] = summary

                    let hasDelta = tokenDelta.total > 0 || costDelta > 0 || summaryDelta.total > 0
                    if hasDelta {
                        // 有实际增量才标记该日期为事件覆盖（无消耗日期不进入 covered）
                        covered.insert(dateKey)
                        dCon[dateKey] = (dCon[dateKey] ?? .zero) + tokenDelta
                        hCon[hourlyKey] = (hCon[hourlyKey] ?? .zero) + tokenDelta
                        dCost[dateKey] = (dCost[dateKey] ?? 0) + costDelta
                        hCost[hourlyKey] = (hCost[hourlyKey] ?? 0) + costDelta
                        dSum[dateKey] = (dSum[dateKey] ?? .zero) + summaryDelta

                        var sd = sDelta[aggregateId] ?? [:]
                        sd[dateKey] = (sd[dateKey] ?? .zero)
                            + SessionDelta(tokens: tokenDelta, cost: costDelta, summary: summaryDelta, lastUpdated: eventTimestamp)
                        sDelta[aggregateId] = sd

                        if let modelKey = sessionModels[aggregateId] {
                            var dm = dMCon[dateKey] ?? [:]
                            dm[modelKey] = (dm[modelKey] ?? .zero) + tokenDelta
                            dMCon[dateKey] = dm
                            var mc = mCost[dateKey] ?? [:]
                            mc[modelKey] = (mc[modelKey] ?? 0) + costDelta
                            mCost[dateKey] = mc
                        }

                        var ac = aCon[dateKey] ?? [:]
                        ac[agent] = (ac[agent] ?? .zero) + tokenDelta
                        aCon[dateKey] = ac
                        var aco = aCost[dateKey] ?? [:]
                        aco[agent] = (aco[agent] ?? 0) + costDelta
                        aCost[dateKey] = aco
                        var pc = pCon[dateKey] ?? [:]
                        pc[projectID] = (pc[projectID] ?? .zero) + tokenDelta
                        pCon[dateKey] = pc
                        var pco = pCost[dateKey] ?? [:]
                        pco[projectID] = (pco[projectID] ?? 0) + costDelta
                        pCost[dateKey] = pco

                        sActive[aggregateId] = (sActive[aggregateId] ?? []).union([dateKey])
                        dActiveS[dateKey] = (dActiveS[dateKey] ?? []).union([aggregateId])
                        dActiveP[dateKey] = (dActiveP[dateKey] ?? []).union([projectID])
                    }
                }

                if hasRevert {
                    // 保存回滚前的完整状态快照（tokens + cost + summary）
                    pendingRollbacks[aggregateId] = SessionDelta(
                        tokens: sessionTokens[aggregateId] ?? tokens,
                        cost: sessionCosts[aggregateId] ?? cost,
                        summary: sessionSummaries[aggregateId] ?? summary,
                        lastUpdated: eventTimestamp
                    )
                    pendingRollbackModels[aggregateId] = sessionModels[aggregateId]
                    pendingRollbackTimestamps[aggregateId] = eventTimestamp
                    sessionTokens[aggregateId] = tokens
                    sessionCosts[aggregateId] = cost
                    sessionSummaries[aggregateId] = summary
                } else if let preState = pendingRollbacks[aggregateId] {
                    let currentState = SessionDelta(
                        tokens: tokens,
                        cost: cost,
                        summary: summary,
                        lastUpdated: eventTimestamp
                    )
                    let positiveRb = positiveRollback(from: preState - currentState)
                    if positiveRb.total > 0 || positiveRb.rolledBackCost > 0 || positiveRb.rolledBackAdditions > 0 || positiveRb.rolledBackDeletions > 0 || positiveRb.rolledBackFiles > 0 {
                        let rollbackTimestamp = pendingRollbackTimestamps[aggregateId] ?? eventTimestamp
                        let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(rollbackTimestamp) / 1000))

                        rb += positiveRb
                        sRb[aggregateId] = (sRb[aggregateId] ?? .zero) + positiveRb

                        var existing = dRb[dateKey] ?? .zero
                        existing += positiveRb
                        dRb[dateKey] = existing

                        let modelKey = pendingRollbackModels[aggregateId] ?? sessionModels[aggregateId]
                        if let mk = modelKey {
                            mRb[mk] = (mRb[mk] ?? .zero) + positiveRb.asTokenData
                            var dailyModel = dMRb[dateKey] ?? [:]
                            dailyModel[mk] = (dailyModel[mk] ?? .zero) + positiveRb.asTokenData
                            dMRb[dateKey] = dailyModel
                        }
                    }
                    pendingRollbacks.removeValue(forKey: aggregateId)
                    pendingRollbackModels.removeValue(forKey: aggregateId)
                    pendingRollbackTimestamps.removeValue(forKey: aggregateId)
                    sessionTokens[aggregateId] = tokens
                    sessionCosts[aggregateId] = cost
                    sessionSummaries[aggregateId] = summary
                } else {
                    sessionTokens[aggregateId] = tokens
                    sessionCosts[aggregateId] = cost
                    sessionSummaries[aggregateId] = summary
                }
            }

            // 写回缓存
            sessionTokenCache = sessionTokens
            sessionModelCache = sessionModels
            pendingRbCache = pendingRollbacks
            pendingRbModelCache = pendingRollbackModels
            pendingRbTimestampCache = pendingRollbackTimestamps

            // 写回累计值
            rollbackRecord = rb
            sessionRollbacks = sRb
            modelRollbacks = mRb
            dailyRollbacks = dRb
            dailyModelRollbacks = dMRb
            dailyConsumption = dCon
            dailyModelConsumption = dMCon
            hourlyConsumption = hCon
            sessionCostCache = sessionCosts
            sessionSummaryCache = sessionSummaries
            dailyCostConsumption = dCost
            hourlyCostConsumption = hCost
            modelCostConsumption = mCost
            dailySummary = dSum
            sessionDailyDelta = sDelta
            sessionActiveDays = sActive
            dailyActiveSessions = dActiveS
            dailyActiveProjects = dActiveP
            agentConsumption = aCon
            projectConsumption = pCon
            agentCostConsumption = aCost
            projectCostConsumption = pCost
            coveredDates = covered

            lastProcessedRowId = maxRowId
        }

        // 独立打开 deveco.db 处理事件（不依赖 ATTACH，避免 WAL 快照问题）
        // 无论 opencode 是否有新事件，deveco 事件都必须独立处理
        refreshDevecoEvents()
    }

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "delta-tracker")

    private func refreshDevecoEvents() {
        var devoDb: OpaquePointer?
        guard sqlite3_open_v2(AppDatabase.devecoPath, &devoDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let devoDb else {
            logger.error("无法打开 deveco.db: \(AppDatabase.devecoPath)")
            return
        }
        defer { sqlite3_close(devoDb) }
        sqlite3_busy_timeout(devoDb, 3000)

        var maxStmt: OpaquePointer?
        let sql = "SELECT COALESCE(MAX(rowid), 0) FROM event"
        guard sqlite3_prepare_v2(devoDb, sql, -1, &maxStmt, nil) == SQLITE_OK else {
            logger.error("deveco.event 查询失败: \(String(cString: sqlite3_errmsg(devoDb)))")
            return
        }
        defer { sqlite3_finalize(maxStmt) }
        var maxRowId: Int64 = 0
        if sqlite3_step(maxStmt) == SQLITE_ROW {
            maxRowId = sqlite3_column_int64(maxStmt, 0)
        }
        let startRowId = devecoLastProcessedRowId
        guard maxRowId > startRowId else { return }

        var sessionTokens = sessionTokenCache
        var sessionModels = sessionModelCache
        var pendingRollbacks = pendingRbCache
        var pendingRollbackModels = pendingRbModelCache
        var pendingRollbackTimestamps = pendingRbTimestampCache

        var rb = rollbackRecord
        var sRb = sessionRollbacks
        var mRb = modelRollbacks
        var dRb = dailyRollbacks
        var dMRb = dailyModelRollbacks
        var dCon = dailyConsumption
        var dMCon = dailyModelConsumption
        var hCon = hourlyConsumption
        var sessionCosts = sessionCostCache
        var sessionSummaries = sessionSummaryCache
        var dCost = dailyCostConsumption
        var hCost = hourlyCostConsumption
        var mCost = modelCostConsumption
        var dSum = dailySummary
        var sDelta = sessionDailyDelta
        var sActive = sessionActiveDays
        var dActiveS = dailyActiveSessions
        var dActiveP = dailyActiveProjects
        var aCon = agentConsumption
        var pCon = projectConsumption
        var aCost = agentCostConsumption
        var pCost = projectCostConsumption
        var covered = coveredDates

        let eventSQL = """
            SELECT rowid, aggregate_id, type, data
            FROM event
            WHERE rowid > ?
            ORDER BY rowid
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(devoDb, eventSQL, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("deveco.event 事件查询失败: \(String(cString: sqlite3_errmsg(devoDb)))")
            sqlite3_finalize(stmt)
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startRowId)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let aggregateId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let type = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  type == "session.updated.1",
                  let data = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let tokensDict = info["tokens"] as? [String: Any]
            else { continue }

            let tokens = TokenData(
                tokensInput: (tokensDict["input"] as? Int) ?? 0,
                tokensOutput: (tokensDict["output"] as? Int) ?? 0,
                tokensReasoning: (tokensDict["reasoning"] as? Int) ?? 0,
                tokensCacheRead: ((tokensDict["cache"] as? [String: Any])?["read"] as? Int) ?? 0,
                tokensCacheWrite: ((tokensDict["cache"] as? [String: Any])?["write"] as? Int) ?? 0
            )
            let cost = (info["cost"] as? Double) ?? 0
            let summary = SummaryData(
                additions: (info["summary"] as? [String: Any])?["additions"] as? Int ?? 0,
                deletions: (info["summary"] as? [String: Any])?["deletions"] as? Int ?? 0,
                files: (info["summary"] as? [String: Any])?["files"] as? Int ?? 0
            )

            let eventTimestamp: Int64 = {
                if let timeObj = info["time"] as? [String: Any], let updated = timeObj["updated"] as? Int64 {
                    return updated
                }
                return 0
            }()

            let agent = (info["agent"] as? String) ?? "unknown"
            let projectID = (info["projectID"] as? String) ?? "unknown"

            if let modelKey = extractModelKey(from: info) {
                sessionModels[aggregateId] = modelKey
            }

            let hasRevert = info["revert"] != nil

            let prevSessionState = sessionTokens[aggregateId]
            if !hasRevert, eventTimestamp > 0 {
                let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(eventTimestamp) / 1000))
                let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(eventTimestamp) / 1000))
                let hourlyKey = "\(dateKey)/\(String(format: "%02d", hour))"

                let tokenDelta: TokenData
                if let prev = prevSessionState {
                    tokenDelta = TokenData(
                        tokensInput: max(0, tokens.tokensInput - prev.tokensInput),
                        tokensOutput: max(0, tokens.tokensOutput - prev.tokensOutput),
                        tokensReasoning: max(0, tokens.tokensReasoning - prev.tokensReasoning),
                        tokensCacheRead: max(0, tokens.tokensCacheRead - prev.tokensCacheRead),
                        tokensCacheWrite: max(0, tokens.tokensCacheWrite - prev.tokensCacheWrite)
                    )
                } else {
                    tokenDelta = tokens
                }
                let prevCost = sessionCosts[aggregateId] ?? 0
                let costDelta = max(0, cost - prevCost)
                let prevSummary = sessionSummaries[aggregateId] ?? .zero
                let summaryDelta = SummaryData(
                    additions: max(0, summary.additions - prevSummary.additions),
                    deletions: max(0, summary.deletions - prevSummary.deletions),
                    files: max(0, summary.files - prevSummary.files)
                )
                sessionCosts[aggregateId] = cost
                sessionSummaries[aggregateId] = summary

                let hasDelta = tokenDelta.total > 0 || costDelta > 0 || summaryDelta.total > 0
                if hasDelta {
                    // 有实际增量才标记该日期为事件覆盖（无消耗日期不进入 covered）
                    covered.insert(dateKey)
                    dCon[dateKey] = (dCon[dateKey] ?? .zero) + tokenDelta
                    hCon[hourlyKey] = (hCon[hourlyKey] ?? .zero) + tokenDelta
                    dCost[dateKey] = (dCost[dateKey] ?? 0) + costDelta
                    hCost[hourlyKey] = (hCost[hourlyKey] ?? 0) + costDelta
                    dSum[dateKey] = (dSum[dateKey] ?? .zero) + summaryDelta

                    var sd = sDelta[aggregateId] ?? [:]
                    sd[dateKey] = (sd[dateKey] ?? .zero)
                        + SessionDelta(tokens: tokenDelta, cost: costDelta, summary: summaryDelta, lastUpdated: eventTimestamp)
                    sDelta[aggregateId] = sd

                    if let modelKey = sessionModels[aggregateId] {
                        var dm = dMCon[dateKey] ?? [:]
                        dm[modelKey] = (dm[modelKey] ?? .zero) + tokenDelta
                        dMCon[dateKey] = dm
                        var mc = mCost[dateKey] ?? [:]
                        mc[modelKey] = (mc[modelKey] ?? 0) + costDelta
                        mCost[dateKey] = mc
                    }

                    var ac = aCon[dateKey] ?? [:]
                    ac[agent] = (ac[agent] ?? .zero) + tokenDelta
                    aCon[dateKey] = ac
                    var aco = aCost[dateKey] ?? [:]
                    aco[agent] = (aco[agent] ?? 0) + costDelta
                    aCost[dateKey] = aco
                    var pc = pCon[dateKey] ?? [:]
                    pc[projectID] = (pc[projectID] ?? .zero) + tokenDelta
                    pCon[dateKey] = pc
                    var pco = pCost[dateKey] ?? [:]
                    pco[projectID] = (pco[projectID] ?? 0) + costDelta
                    pCost[dateKey] = pco

                    sActive[aggregateId] = (sActive[aggregateId] ?? []).union([dateKey])
                    dActiveS[dateKey] = (dActiveS[dateKey] ?? []).union([aggregateId])
                    dActiveP[dateKey] = (dActiveP[dateKey] ?? []).union([projectID])
                }
            }

            if hasRevert {
                // 保存回滚前的完整状态快照（tokens + cost + summary）
                pendingRollbacks[aggregateId] = SessionDelta(
                    tokens: sessionTokens[aggregateId] ?? tokens,
                    cost: sessionCosts[aggregateId] ?? cost,
                    summary: sessionSummaries[aggregateId] ?? summary,
                    lastUpdated: eventTimestamp
                )
                pendingRollbackModels[aggregateId] = sessionModels[aggregateId]
                pendingRollbackTimestamps[aggregateId] = eventTimestamp
                sessionTokens[aggregateId] = tokens
                sessionCosts[aggregateId] = cost
                sessionSummaries[aggregateId] = summary
            } else if let preState = pendingRollbacks[aggregateId] {
                let currentState = SessionDelta(
                    tokens: tokens,
                    cost: cost,
                    summary: summary,
                    lastUpdated: eventTimestamp
                )
                let positiveRb = positiveRollback(from: preState - currentState)
                if positiveRb.total > 0 || positiveRb.rolledBackCost > 0 || positiveRb.rolledBackAdditions > 0 || positiveRb.rolledBackDeletions > 0 || positiveRb.rolledBackFiles > 0 {
                    let rollbackTimestamp = pendingRollbackTimestamps[aggregateId] ?? eventTimestamp
                    let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(rollbackTimestamp) / 1000))

                    rb += positiveRb
                    sRb[aggregateId] = (sRb[aggregateId] ?? .zero) + positiveRb

                    var existing = dRb[dateKey] ?? .zero
                    existing += positiveRb
                    dRb[dateKey] = existing

                    let modelKey = pendingRollbackModels[aggregateId] ?? sessionModels[aggregateId]
                    if let mk = modelKey {
                        mRb[mk] = (mRb[mk] ?? .zero) + positiveRb.asTokenData
                        var dailyModel = dMRb[dateKey] ?? [:]
                        dailyModel[mk] = (dailyModel[mk] ?? .zero) + positiveRb.asTokenData
                        dMRb[dateKey] = dailyModel
                    }
                }
                pendingRollbacks.removeValue(forKey: aggregateId)
                pendingRollbackModels.removeValue(forKey: aggregateId)
                pendingRollbackTimestamps.removeValue(forKey: aggregateId)
                sessionTokens[aggregateId] = tokens
                sessionCosts[aggregateId] = cost
                sessionSummaries[aggregateId] = summary
            } else {
                sessionTokens[aggregateId] = tokens
                sessionCosts[aggregateId] = cost
                sessionSummaries[aggregateId] = summary
            }
        }

        sessionTokenCache = sessionTokens
        sessionModelCache = sessionModels
        pendingRbCache = pendingRollbacks
        pendingRbModelCache = pendingRollbackModels
        pendingRbTimestampCache = pendingRollbackTimestamps

        rollbackRecord = rb
        sessionRollbacks = sRb
        modelRollbacks = mRb
        dailyRollbacks = dRb
        dailyModelRollbacks = dMRb
        dailyConsumption = dCon
        dailyModelConsumption = dMCon
        hourlyConsumption = hCon
        sessionCostCache = sessionCosts
        sessionSummaryCache = sessionSummaries
        dailyCostConsumption = dCost
        hourlyCostConsumption = hCost
        modelCostConsumption = mCost
        dailySummary = dSum
        sessionDailyDelta = sDelta
        sessionActiveDays = sActive
        dailyActiveSessions = dActiveS
        dailyActiveProjects = dActiveP
        agentConsumption = aCon
        projectConsumption = pCon
        agentCostConsumption = aCost
        projectCostConsumption = pCost
        coveredDates = covered

        devecoLastProcessedRowId = maxRowId
    }

    /// 将回滚差量截断为正值，记入 rollback 账本
    private func positiveRollback(from diff: SessionDelta) -> RollbackRecord {
        RollbackRecord(
            rolledBackInput: max(0, diff.tokens.tokensInput),
            rolledBackOutput: max(0, diff.tokens.tokensOutput),
            rolledBackReasoning: max(0, diff.tokens.tokensReasoning),
            rolledBackCacheRead: max(0, diff.tokens.tokensCacheRead),
            rolledBackCacheWrite: max(0, diff.tokens.tokensCacheWrite),
            rolledBackCost: max(0, diff.cost),
            rolledBackAdditions: max(0, diff.summary.additions),
            rolledBackDeletions: max(0, diff.summary.deletions),
            rolledBackFiles: max(0, diff.summary.files)
        )
    }

    func rollback(year: String?, month: String?, day: String?) -> RollbackRecord {
        dailyRollbacks.filter { key, _ in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        }.reduce(.zero) { $0 + $1.value }
    }

    func modelRollbacks(year: String?, month: String?, day: String?) -> [String: TokenData] {
        let matchingKeys = Set(dailyModelRollbacks.keys.filter { key in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        })
        var result: [String: TokenData] = [:]
        for key in matchingKeys {
            guard let modelRb = dailyModelRollbacks[key] else { continue }
            for (modelKey, tokens) in modelRb {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    func rollback(from startDate: Date, to endDate: Date) -> RollbackRecord {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailyRollbacks.filter { keys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelRollbacks(from startDate: Date, to endDate: Date) -> [String: TokenData] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        var result: [String: TokenData] = [:]
        for (key, modelRb) in dailyModelRollbacks where keys.contains(key) {
            for (modelKey, tokens) in modelRb {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    private func dateKeysInRange(from startDate: Date, to endDate: Date) -> Set<String> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        guard let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate)) else { return [] }
        var keys: Set<String> = []
        var current = start
        while current < end {
            keys.insert(Self.dailyDateFormatter.string(from: current))
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return keys
    }

    func rollback(days: Int) -> RollbackRecord {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return .zero }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        return dailyRollbacks.filter { dateKeys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelRollbacks(days: Int) -> [String: TokenData] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [:] }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        var result: [String: TokenData] = [:]
        for (key, modelRb) in dailyModelRollbacks where dateKeys.contains(key) {
            for (modelKey, tokens) in modelRb {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    // MARK: - Daily Consumption Query Methods

    func consumption(year: String?, month: String?, day: String?) -> TokenData {
        dailyConsumption.filter { key, _ in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        }.reduce(.zero) { $0 + $1.value }
    }

    func modelConsumption(year: String?, month: String?, day: String?) -> [String: TokenData] {
        let matchingKeys = Set(dailyModelConsumption.keys.filter { key in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        })
        var result: [String: TokenData] = [:]
        for key in matchingKeys {
            guard let mc = dailyModelConsumption[key] else { continue }
            for (modelKey, tokens) in mc {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    func consumption(from startDate: Date, to endDate: Date) -> TokenData {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailyConsumption.filter { keys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelConsumption(from startDate: Date, to endDate: Date) -> [String: TokenData] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        var result: [String: TokenData] = [:]
        for (key, mc) in dailyModelConsumption where keys.contains(key) {
            for (modelKey, tokens) in mc {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    func consumption(days: Int) -> TokenData {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return .zero }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        return dailyConsumption.filter { dateKeys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelConsumption(days: Int) -> [String: TokenData] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [:] }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        var result: [String: TokenData] = [:]
        for (key, mc) in dailyModelConsumption where dateKeys.contains(key) {
            for (modelKey, tokens) in mc {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    // MARK: - Daily ModelUsage Conversion

    func dailyModelUsage(from startDate: Date, to endDate: Date) -> [DailyModelUsage] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        var result: [DailyModelUsage] = []
        for dateKey in keys.sorted() {
            guard let date = df.date(from: dateKey) else { continue }
            guard let mc = dailyModelConsumption[dateKey], !mc.isEmpty else { continue }
            for (modelKey, tokens) in mc {
                let parts = modelKey.split(separator: "/")
                let providerID = String(parts[0])
                let modelId = parts.count > 1 ? String(parts[1]) : "unknown"
                let variant = parts.count > 2 ? String(parts[2]) : "default"
                result.append(DailyModelUsage(
                    id: "\(dateKey)/\(modelKey)",
                    date: date,
                    providerID: providerID,
                    modelId: modelId,
                    variant: variant,
                    inputTokens: tokens.tokensInput,
                    outputTokens: tokens.tokensOutput,
                    cacheReadTokens: tokens.tokensCacheRead,
                    reasoningTokens: tokens.tokensReasoning,
                    cacheWriteTokens: tokens.tokensCacheWrite
                ))
            }
        }
        return result
    }

    // MARK: - 事件时间维度查询（成本/变更量/会话增量/Agent/项目）

    func coveredDateKeys() -> Set<String> { coveredDates }

    func consumptionCost(year: String?, month: String?, day: String?) -> Double {
        dailyCostConsumption.filter { key, _ in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        }.values.reduce(0, +)
    }

    func consumptionCost(from startDate: Date, to endDate: Date) -> Double {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailyCostConsumption.filter { keys.contains($0.key) }.values.reduce(0, +)
    }

    func consumptionCost(days: Int) -> Double {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return 0 }
        return consumptionCost(from: startDate, to: today)
    }

    func summary(year: String?, month: String?, day: String?) -> SummaryData {
        dailySummary.filter { key, _ in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        }.values.reduce(.zero) { $0 + $1 }
    }

    func summary(from startDate: Date, to endDate: Date) -> SummaryData {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailySummary.filter { keys.contains($0.key) }.values.reduce(.zero) { $0 + $1 }
    }

    func summary(days: Int) -> SummaryData {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return .zero }
        return summary(from: startDate, to: today)
    }

    func dailyConsumptionSeries(from startDate: Date, to endDate: Date) -> [String: TokenData] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailyConsumption.filter { keys.contains($0.key) }
    }

    func dailyCostSeries(from startDate: Date, to endDate: Date) -> [String: Double] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailyCostConsumption.filter { keys.contains($0.key) }
    }

    func sessionDelta(in dateKeys: Set<String>) -> [String: SessionDelta] {
        var result: [String: SessionDelta] = [:]
        for (sessionID, deltas) in sessionDailyDelta {
            for (dateKey, delta) in deltas where dateKeys.contains(dateKey) {
                result[sessionID] = (result[sessionID] ?? .zero) + delta
            }
        }
        return result
    }

    func activeSessionIDs(in dateKeys: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for (sessionID, days) in sessionActiveDays where !days.isDisjoint(with: dateKeys) {
            result.insert(sessionID)
        }
        return result
    }

    func activeProjectIDs(in dateKeys: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for (dateKey, projects) in dailyActiveProjects where dateKeys.contains(dateKey) {
            result.formUnion(projects)
        }
        return result
    }

    func activeSessionCount(year: String?, month: String?, day: String?) -> Int {
        var count = 0
        for (dateKey, sessions) in dailyActiveSessions where Self.matchesDateFilter(dateKey, year: year, month: month, day: day) {
            count += sessions.count
        }
        return count
    }

    func activeProjectCount(year: String?, month: String?, day: String?) -> Int {
        var result: Set<String> = []
        for (dateKey, projects) in dailyActiveProjects where Self.matchesDateFilter(dateKey, year: year, month: month, day: day) {
            result.formUnion(projects)
        }
        return result.count
    }

    func agentConsumption(year: String?, month: String?, day: String?) -> [String: TokenData] {
        var result: [String: TokenData] = [:]
        for (dateKey, agents) in agentConsumption where Self.matchesDateFilter(dateKey, year: year, month: month, day: day) {
            for (agent, tokens) in agents {
                result[agent] = (result[agent] ?? .zero) + tokens
            }
        }
        return result
    }

    func projectConsumption(year: String?, month: String?, day: String?) -> [String: TokenData] {
        var result: [String: TokenData] = [:]
        for (dateKey, projects) in projectConsumption where Self.matchesDateFilter(dateKey, year: year, month: month, day: day) {
            for (projectID, tokens) in projects {
                result[projectID] = (result[projectID] ?? .zero) + tokens
            }
        }
        return result
    }

    func agentCostConsumption(year: String?, month: String?, day: String?) -> [String: Double] {
        var result: [String: Double] = [:]
        for (dateKey, agents) in agentCostConsumption where Self.matchesDateFilter(dateKey, year: year, month: month, day: day) {
            for (agent, cost) in agents {
                result[agent] = (result[agent] ?? 0) + cost
            }
        }
        return result
    }

    func projectCostConsumption(year: String?, month: String?, day: String?) -> [String: Double] {
        var result: [String: Double] = [:]
        for (dateKey, projects) in projectCostConsumption where Self.matchesDateFilter(dateKey, year: year, month: month, day: day) {
            for (projectID, cost) in projects {
                result[projectID] = (result[projectID] ?? 0) + cost
            }
        }
        return result
    }

    private static func matchesDateFilter(_ dateKey: String, year: String?, month: String?, day: String?) -> Bool {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3 else { return false }
        if let y = year, String(parts[0]) != y { return false }
        if let m = month, String(parts[1]) != m { return false }
        if let d = day, String(parts[2]) != d { return false }
        return true
    }

    private func extractModelKey(from info: [String: Any]) -> String? {
        guard let modelDict = info["model"] as? [String: Any],
              let modelId = modelDict["id"] as? String else { return nil }
        let providerID = modelDict["providerID"] as? String ?? "opencode"
        let variant = modelDict["variant"] as? String ?? "default"
        let normalized = variant == "max" ? "default" : variant
        return "\(providerID)/\(modelId)/\(normalized)"
    }
}
