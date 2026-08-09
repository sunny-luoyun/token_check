# 全项目统一"事件时间"统计口径实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全项目所有时间段统计统一按事件发生时间（`event.info.time.updated`）归属，跨天会话的当日增量计入当天，历史（2026-06-25 前）由 session 表兜底。

**Architecture:** TokenDeltaTracker 升级为统一统计引擎（新增 cost/summary/agent/project/会话增量维度），WidgetDataService 与 DatabaseService 所有时间段统计改为"事件优先 + session 兜底"，ViewModel 保证 load 前 tracker 已 refresh。

**Tech Stack:** Swift / SwiftUI / WidgetKit / SQLite3（本项目无测试 target，验证以 `xcodebuild` 编译 + 运行时数据实测为主）

**参考设计文档:** `docs/superpowers/specs/2026-08-09-event-time-statistics-design.md`

## Global Constraints

- 全项目无测试框架，每个任务以编译通过（`xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`）作为验证门槛，最终任务做数据实测
- 事件时间口径优先，session 表（`time_created`）仅兜底 2026-06-25 之前缺失的历史
- rollback（revert）语义沿用现有"不扣减、记正数 rollback"，新增维度不包含 rollback 正数
- `messageCount` 保持 SQL 口径（消息即时产生）
- 不修改任何 widget 的 `kind` 值（见 AGENTS.md chronod 注意事项）
- 代码注释与提交信息使用中文
- deveco.db 与 opencode.db 的事件处理代码必须同步修改（两份逻辑）
- 类型命名：`SummaryData`、`SessionDelta`、`EventAccumulator`（本计划不使用 Accumulator，沿用现有局部变量模式）

---

### Task 1: 数据模型扩展

**Files:**
- Create: `token_check/Models/SummaryData.swift`
- Create: `token_check/Models/SessionDelta.swift`
- Modify: `token_check/Models/RollbackRecord.swift`

**Interfaces:**
- Produces:
  - `struct SummaryData: Codable, Equatable` — `var additions/deletions/files: Int`；`static let zero`；`var total: Int`；`+`、`+=`、`-` 运算符
  - `struct SessionDelta: Equatable` — `var tokens: TokenData`、`var cost: Double`、`var summary: SummaryData`、`var lastUpdated: Int64`；`static let zero`；`var totalTokens: Int`；`+`、`+=` 运算符
  - `RollbackRecord` 增加 `rolledBackCost: Double`、`rolledBackAdditions/Deletions/Files: Int`（Codable 兼容旧数据，新字段 `decodeIfPresent`）

- [ ] **Step 1: 新建 SummaryData.swift**

```swift
import Foundation

struct SummaryData: Codable, Equatable {
    var additions: Int
    var deletions: Int
    var files: Int

    static let zero = SummaryData(additions: 0, deletions: 0, files: 0)

    var total: Int { additions + deletions + files }

    static func + (lhs: SummaryData, rhs: SummaryData) -> SummaryData {
        SummaryData(
            additions: lhs.additions + rhs.additions,
            deletions: lhs.deletions + rhs.deletions,
            files: lhs.files + rhs.files
        )
    }

    static func += (lhs: inout SummaryData, rhs: SummaryData) {
        lhs = lhs + rhs
    }

    static func - (lhs: SummaryData, rhs: SummaryData) -> SummaryData {
        SummaryData(
            additions: lhs.additions - rhs.additions,
            deletions: lhs.deletions - rhs.deletions,
            files: lhs.files - rhs.files
        )
    }
}
```

- [ ] **Step 2: 新建 SessionDelta.swift**

```swift
import Foundation

struct SessionDelta: Equatable {
    var tokens: TokenData
    var cost: Double
    var summary: SummaryData
    var lastUpdated: Int64

    static let zero = SessionDelta(tokens: .zero, cost: 0, summary: .zero, lastUpdated: 0)

    var totalTokens: Int { tokens.total }

    static func + (lhs: SessionDelta, rhs: SessionDelta) -> SessionDelta {
        SessionDelta(
            tokens: lhs.tokens + rhs.tokens,
            cost: lhs.cost + rhs.cost,
            summary: lhs.summary + rhs.summary,
            lastUpdated: max(lhs.lastUpdated, rhs.lastUpdated)
        )
    }

    static func += (lhs: inout SessionDelta, rhs: SessionDelta) {
        lhs = lhs + rhs
    }

    static func - (lhs: SessionDelta, rhs: SessionDelta) -> SessionDelta {
        SessionDelta(
            tokens: lhs.tokens - rhs.tokens,
            cost: lhs.cost - rhs.cost,
            summary: lhs.summary - rhs.summary,
            lastUpdated: lhs.lastUpdated
        )
    }
}
```

- [ ] **Step 3: 扩展 RollbackRecord.swift**

替换整个文件为：

```swift
import Foundation

struct RollbackRecord: Codable {
    var rolledBackInput: Int
    var rolledBackOutput: Int
    var rolledBackReasoning: Int
    var rolledBackCacheRead: Int
    var rolledBackCacheWrite: Int
    var rolledBackCost: Double
    var rolledBackAdditions: Int
    var rolledBackDeletions: Int
    var rolledBackFiles: Int

    static let zero = RollbackRecord(
        rolledBackInput: 0,
        rolledBackOutput: 0,
        rolledBackReasoning: 0,
        rolledBackCacheRead: 0,
        rolledBackCacheWrite: 0,
        rolledBackCost: 0,
        rolledBackAdditions: 0,
        rolledBackDeletions: 0,
        rolledBackFiles: 0
    )

    var total: Int {
        rolledBackInput + rolledBackOutput + rolledBackReasoning + rolledBackCacheRead + rolledBackCacheWrite
    }

    var asTokenData: TokenData {
        TokenData(
            tokensInput: rolledBackInput,
            tokensOutput: rolledBackOutput,
            tokensReasoning: rolledBackReasoning,
            tokensCacheRead: rolledBackCacheRead,
            tokensCacheWrite: rolledBackCacheWrite
        )
    }

    var asSummaryData: SummaryData {
        SummaryData(
            additions: rolledBackAdditions,
            deletions: rolledBackDeletions,
            files: rolledBackFiles
        )
    }

    init(
        rolledBackInput: Int, rolledBackOutput: Int, rolledBackReasoning: Int,
        rolledBackCacheRead: Int, rolledBackCacheWrite: Int,
        rolledBackCost: Double, rolledBackAdditions: Int, rolledBackDeletions: Int, rolledBackFiles: Int
    ) {
        self.rolledBackInput = rolledBackInput
        self.rolledBackOutput = rolledBackOutput
        self.rolledBackReasoning = rolledBackReasoning
        self.rolledBackCacheRead = rolledBackCacheRead
        self.rolledBackCacheWrite = rolledBackCacheWrite
        self.rolledBackCost = rolledBackCost
        self.rolledBackAdditions = rolledBackAdditions
        self.rolledBackDeletions = rolledBackDeletions
        self.rolledBackFiles = rolledBackFiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rolledBackInput = try c.decode(Int.self, forKey: .rolledBackInput)
        rolledBackOutput = try c.decode(Int.self, forKey: .rolledBackOutput)
        rolledBackReasoning = try c.decode(Int.self, forKey: .rolledBackReasoning)
        rolledBackCacheRead = try c.decode(Int.self, forKey: .rolledBackCacheRead)
        rolledBackCacheWrite = try c.decode(Int.self, forKey: .rolledBackCacheWrite)
        rolledBackCost = try c.decodeIfPresent(Double.self, forKey: .rolledBackCost) ?? 0
        rolledBackAdditions = try c.decodeIfPresent(Int.self, forKey: .rolledBackAdditions) ?? 0
        rolledBackDeletions = try c.decodeIfPresent(Int.self, forKey: .rolledBackDeletions) ?? 0
        rolledBackFiles = try c.decodeIfPresent(Int.self, forKey: .rolledBackFiles) ?? 0
    }

    static func + (lhs: RollbackRecord, rhs: RollbackRecord) -> RollbackRecord {
        RollbackRecord(
            rolledBackInput: lhs.rolledBackInput + rhs.rolledBackInput,
            rolledBackOutput: lhs.rolledBackOutput + rhs.rolledBackOutput,
            rolledBackReasoning: lhs.rolledBackReasoning + rhs.rolledBackReasoning,
            rolledBackCacheRead: lhs.rolledBackCacheRead + rhs.rolledBackCacheRead,
            rolledBackCacheWrite: lhs.rolledBackCacheWrite + rhs.rolledBackCacheWrite,
            rolledBackCost: lhs.rolledBackCost + rhs.rolledBackCost,
            rolledBackAdditions: lhs.rolledBackAdditions + rhs.rolledBackAdditions,
            rolledBackDeletions: lhs.rolledBackDeletions + rhs.rolledBackDeletions,
            rolledBackFiles: lhs.rolledBackFiles + rhs.rolledBackFiles
        )
    }

    static func += (lhs: inout RollbackRecord, rhs: RollbackRecord) {
        lhs = lhs + rhs
    }

    static func += (lhs: inout RollbackRecord, rhs: TokenData) {
        lhs.rolledBackInput += rhs.tokensInput
        lhs.rolledBackOutput += rhs.tokensOutput
        lhs.rolledBackReasoning += rhs.tokensReasoning
        lhs.rolledBackCacheRead += rhs.tokensCacheRead
        lhs.rolledBackCacheWrite += rhs.tokensCacheWrite
    }

    static func += (lhs: inout RollbackRecord, rhs: SummaryData) {
        lhs.rolledBackAdditions += rhs.additions
        lhs.rolledBackDeletions += rhs.deletions
        lhs.rolledBackFiles += rhs.files
    }

    static func += (lhs: inout RollbackRecord, cost: Double) {
        lhs.rolledBackCost += cost
    }
}
```

注意：原文件里没有显式 `init(...)`（Codable 合成），这里显式写了全参 init 与 decode init，`CodingKeys` 由 Codable 自动合成，`encode` 自动编码全部字段（旧数据 decode 缺失字段时用 `decodeIfPresent` 兜底）。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add token_check/Models/SummaryData.swift token_check/Models/SessionDelta.swift token_check/Models/RollbackRecord.swift
git commit -m "feat: 新增 SummaryData/SessionDelta 模型，扩展 RollbackRecord 支持成本与变更量"
```

---

### Task 2: TokenDeltaTracker 状态字段与事件处理逻辑扩展

**Files:**
- Modify: `token_check/Services/TokenDeltaTracker.swift`

**Interfaces:**
- Consumes: `SummaryData`、`SessionDelta`、扩展后的 `RollbackRecord`（Task 1）
- Produces（后续任务依赖的字段与变量，均为 `@Atomic` 属性或局部变量）:
  - `sessionCostCache: [String: Double]`、`sessionSummaryCache: [String: SummaryData]`
  - `dailyCostConsumption: [String: Double]`、`hourlyCostConsumption: [String: Double]`、`modelCostConsumption: [String: [String: Double]]`
  - `dailySummary: [String: SummaryData]`
  - `sessionDailyDelta: [String: [String: SessionDelta]]`（key: sessionID → dateKey）
  - `sessionActiveDays: [String: Set<String>]`
  - `dailyActiveSessions: [String: Set<String>]`、`dailyActiveProjects: [String: Set<String>]`
  - `agentConsumption: [String: [String: TokenData]]`、`projectConsumption: [String: [String: TokenData]]`
  - `agentCostConsumption: [String: [String: Double]]`、`projectCostConsumption: [String: [String: Double]]`
  - `coveredDates: Set<String>`（有事件处理过的日期，用于判定是否可走事件口径）
  - 会话级 rollback 从 `sessionRollbacks: [String: TokenData]` 改为 `sessionRollbacks: [String: RollbackRecord]`（Task 2 一并完成，SessionListView 读 `sessionRollbacks[id].asTokenData` 处需同步改为 `.asTokenData`）
  - 回滚前状态缓存 `pendingRollbacks`/`pendingRbCache` 类型从 `[String: TokenData]` 改为 `[String: SessionDelta]`（保存回滚前的 tokens+cost+summary 完整快照，用于结算 rollback 差量）

- [ ] **Step 1: 新增状态字段**

在 `TokenDeltaTracker` 类内、`hourlyConsumption` 字段（第 26 行）之后插入：

```swift
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
```

- [ ] **Step 2: 将 `sessionRollbacks` 类型改为 `[String: RollbackRecord]`，`pendingRollbacks` 改为 `[String: SessionDelta]`**

将第 20 行 `@Atomic var sessionRollbacks: [String: TokenData] = [:]` 改为 `@Atomic var sessionRollbacks: [String: RollbackRecord] = [:]`；将第 33 行 `@Atomic var pendingRbCache: [String: TokenData] = [:]` 改为 `@Atomic var pendingRbCache: [String: SessionDelta] = [:]`（`pendingRollbacks` 局部变量的类型随之变化，无需单独声明）。

新增私有 helper（加在 `refreshDevecoEvents` 之后），把差量转为正数 rollback：

```swift
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
```

- [ ] **Step 3: 扩展 refresh() 的 while 循环体（opencode.db 段）**

将 `refresh(db:)` 中（原第 96-206 行）的 while 循环体整体替换为以下代码。同时在 `var dMCon = dailyModelConsumption`（原第 77 行）附近补充加载新增状态：

```swift
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
```

while 循环体（替换原 96-206 行）：

```swift
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
                if eventTimestamp > 0 {
                    let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(eventTimestamp) / 1000))
                    covered.insert(dateKey)
                }

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
                    if positiveRb.total > 0 || positiveRb.rolledBackCost > 0 || positiveRb.rolledBackAdditions > 0 {
                        let rollbackTimestamp = pendingRollbackTimestamps[aggregateId] ?? eventTimestamp
                        let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(rollbackTimestamp) / 1000))

                        rb += positiveRb
                        sRb[aggregateId] = (sRb[aggregateId] ?? .zero) + positiveRb

                        var existing = dRb[dateKey] ?? .zero
                        existing += positiveRb
                        dRb[dateKey] = existing

                        let modelKey = pendingRollbackModels[aggregateId] ?? sessionModels[aggregateId]
                        if let mk = modelKey {
                            mRb[mk] = (mRb[mk] ?? .zero) + positiveRb
                            var dailyModel = dMRb[dateKey] ?? [:]
                            dailyModel[mk] = (dailyModel[mk] ?? .zero) + positiveRb
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
```

- [ ] **Step 4: 更新 refresh() 的写回段（原第 208-225 行）**

将写回段替换为：

```swift
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
```

- [ ] **Step 5: 同步修改 refreshDevecoEvents()**

将 `refreshDevecoEvents()` 中（原第 259-400 行）做与 Step 3/4 相同的修改：加载新增状态（同 Step 3 的变量声明清单）、替换 while 循环体（内容与 Step 3 完全相同）、替换写回段（同 Step 4，注意 `devecoLastProcessedRowId = maxRowId` 保留在最后）。

- [ ] **Step 6: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: BUILD SUCCEEDED（若 `SessionListView.swift:54,63` 因 `sessionRollbacks` 类型变化报错，将其 `viewModel.sessionRollbacks[session.id]` 用法改为 `.asTokenData`）

- [ ] **Step 7: 提交**

```bash
git add token_check/Services/TokenDeltaTracker.swift token_check/Views/SessionListView.swift
git commit -m "feat: TokenDeltaTracker 扩展成本/变更量/会话增量/Agent/项目维度累计，按事件时间归属"
```

---

### Task 3: TokenDeltaTracker 查询 API

**Files:**
- Modify: `token_check/Services/TokenDeltaTracker.swift`

**Interfaces:**
- Consumes: Task 2 新增字段
- Produces（供 Task 4/5 使用）:
  - `func consumptionCost(year: String?, month: String?, day: String?) -> Double`
  - `func consumptionCost(from startDate: Date, to endDate: Date) -> Double`
  - `func consumptionCost(days: Int) -> Double`
  - `func summary(year: String?, month: String?, day: String?) -> SummaryData`
  - `func summary(from startDate: Date, to endDate: Date) -> SummaryData`
  - `func summary(days: Int) -> SummaryData`
  - `func sessionDelta(in dateKeys: Set<String>) -> [String: SessionDelta]`
  - `func activeSessionIDs(in dateKeys: Set<String>) -> Set<String>`
  - `func activeProjectIDs(in dateKeys: Set<String>) -> Set<String>`
  - `func activeSessionCount(year: String?, month: String?, day: String?) -> Int`
  - `func activeProjectCount(year: String?, month: String?, day: String?) -> Int`
  - `func agentConsumption(year: String?, month: String?, day: String?) -> [String: TokenData]`
  - `func projectConsumption(year: String?, month: String?, day: String?) -> [String: TokenData]`
  - `func agentCostConsumption(year: String?, month: String?, day: String?) -> [String: Double]`
  - `func projectCostConsumption(year: String?, month: String?, day: String?) -> [String: Double]`
  - `func dailyConsumptionSeries(from startDate: Date, to endDate: Date) -> [String: TokenData]`
  - `func dailyCostSeries(from startDate: Date, to endDate: Date) -> [String: Double]`
  - `var coveredDateKeys: Set<String> { coveredDates }`
  - `func dateKeys(in range: (Date, Date)) -> Set<String>`（内部复用 dateKeysInRange）

- [ ] **Step 1: 在 `// MARK: - Daily Consumption Query Methods` 段后追加查询方法**

在 `dailyModelUsage(from:to:)` 方法之后（第 603 行前）追加：

```swift
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
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add token_check/Services/TokenDeltaTracker.swift
git commit -m "feat: TokenDeltaTracker 新增事件时间维度查询 API"
```

---

### Task 4: WidgetDataService 改造

**Files:**
- Modify: `token_check/Services/WidgetDataService.swift`

**Interfaces:**
- Consumes: Task 3 的查询 API
- Produces: `fetchTodayUsage()`、`fetchYearlyData()`、`fetchMonthData()` 返回值口径统一为事件时间优先

- [ ] **Step 1: 新增私有 helper（放在 `todayStartMilliseconds()` 附近）**

```swift
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
```

- [ ] **Step 2: 改写 `fetchTodayUsage()` 的今日统计取值（原第 156-184 行）**

将第 156-184 行的取值段替换为：

```swift
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
```

同时在 Step 1 的 helper 段后追加：

```swift
    private static func dateParts(from key: String) -> (year: String?, month: String?, day: String?) {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return (nil, nil, nil) }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }
```

- [ ] **Step 3: 改写 `todayCost` 与 `projectCount` 取值（原第 187、189 行）**

```swift
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
```

> 原第 186-187 行的 `let messageCount = fetchTodayMessageCount(db, todayStart)` 与 `let projectCount = fetchTodayProjectCount(db, todayStart)` 中，messageCount 保持 SQL 不动，projectCount 用上面代码替换。

- [ ] **Step 5: 改写 `dailyTokens` / `dailyCosts`（原第 191-200 行）**

```swift
        // 事件时间口径优先：事件覆盖的日期用 tracker，未覆盖的日期用 session 表兜底
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
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
```

并新增私有 helper（放在 `fillMissingDays` 附近）：

```swift
    private func dailyDateFrom(_ key: String) -> Date? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: key)
    }
```

- [ ] **Step 6: 改写 `fetchMonthData()`（原第 287-350 行）**

在现有 SQL 聚合（`var existing: [String: Int] = [:]` 与 while 循环）之后、`days` 构建循环之前插入覆盖逻辑（热力图结构无 cost 字段，只覆盖 token 值）：

```swift
        // 事件时间口径优先：事件覆盖的日期用 tracker 值覆盖
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let eventSeries = TokenDeltaTracker.shared.dailyConsumptionSeries(from: monthStart, to: monthEnd.addingTimeInterval(-1))
        for (key, tokens) in eventSeries where covered.contains(key) {
            if let date = df.date(from: key) {
                existing[key] = tokens.total
            }
        }
```

> 注意：插入位置必须在原代码 `let df = DateFormatter()`（第 328-330 行）**之后**，`df.dateFormat = "yyyy-MM-dd"` 已设置。

`MonthlyHeatmapData` 返回值不变（`totalTokens` 用事件口径；`days` 的 totalTokens 用事件口径；`avgDailyTokens` 同理）。

- [ ] **Step 7: 改写 `fetchYearlyData()`（原第 223-285 行）**

在 SQL 聚合（`var existing: [String: Int] = [:]` 与 while 循环）之后、`days` 构建循环之前插入覆盖逻辑（同样在 `let df = DateFormatter()` 第 263-265 行之后插入）：

```swift
        // 事件时间口径优先：事件覆盖的日期用 tracker 值覆盖
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let eventSeries = TokenDeltaTracker.shared.dailyConsumptionSeries(from: yearStart, to: yearEnd.addingTimeInterval(-1))
        for (key, tokens) in eventSeries where covered.contains(key) {
            if let d = df.date(from: key) {
                existing[key] = tokens.total
            }
        }
```

`YearlyHeatmapData` 返回不变（`avgDailyTokens` 仍按 totalTokens / totalDays）。

- [ ] **Step 8: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: 提交**

```bash
git add token_check/Services/WidgetDataService.swift
git commit -m "feat: Widget 数据链路改为事件时间口径，session 表兑底"
```

---

### Task 5: DatabaseService 改造

**Files:**
- Modify: `token_check/Services/DatabaseService.swift`

**Interfaces:**
- Consumes: Task 3 的查询 API
- Produces: `fetchDailyUsageByModel`、`fetchModelCostBreakdown`、`fetchCostSummary`、`fetchAgentUsage`、`fetchProjectUsage`、`fetchEfficiencySummary`、`fetchEfficiencyDetail`、`fetchSessions`、`fetchAvailablePeriods`、`fetchAvailableDays` 全部事件优先 + session 兜底

- [ ] **Step 1: 新增 helper（放在 `buildDateRangeClause` 后）**

```swift
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
```

- [ ] **Step 2: 改写 `fetchDailyUsageByModel`（原第 163-221 行）**

将方法体改为事件优先合并：

```swift
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
        for (dateKey, models) in eventMap {
            for usage in models.values {
                result.append(usage)
            }
        }
        return result.sorted { $0.date < $1.date }
    }
```

并新增静态 helper：

```swift
    private static func dateFromKey(_ key: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: key) ?? .now
    }
```

> 说明：原 `days` 参数分支（无 startDate/endDate/year 时）在调用方均传了 from/to 或 year/month/day，此处统一用事件优先合并；原 `year/month/day` 的 strftime SQL 分支不再使用（`keys` 已含该语义）。`fetchDailyUsage`（无调用者）保持原样不动。

- [ ] **Step 3: 改写 `fetchModelCostBreakdown` 与 `fetchCostSummary`**

`fetchModelCostBreakdown`（原 252-291 行）改为事件优先 + session 兜底（移除 max 合并）：

```swift
    func fetchModelCostBreakdown(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, pricingRules: [ModelPricingRule] = [], referenceDate: Date = .now) throws -> [ModelCostBreakdown] {
        let pricingLookup = ModelPricingStore.lookup(from: pricingRules)
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)

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
                sessions: (existing?.sessions ?? 0) + 0,
                cacheMissTokens: (existing?.cacheMissTokens ?? 0) + tokens.tokensInput,
                cacheHitTokens: (existing?.cacheHitTokens ?? 0) + tokens.tokensCacheRead,
                outputTokens: (existing?.outputTokens ?? 0) + tokens.tokensOutput,
                reasoningTokens: (existing?.reasoningTokens ?? 0) + tokens.tokensReasoning,
                pricing: pricing,
                referenceDate: referenceDate
            )
        }

        // 兜底：事件未覆盖日期用 session 表
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
            \(buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).0)
            GROUP BY provider_id, model_id, variant
            ORDER BY SUM(tokens_input) DESC
            """,
            parameters: buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).1
        ) { stmt in
            let providerID = text(stmt, 0) ?? "opencode"
            let modelId = text(stmt, 1) ?? "unknown"
            let variant = text(stmt, 2) ?? "default"
            return (providerID, modelId, variant, int(stmt, 3), int(stmt, 4), int(stmt, 5), int(stmt, 6), int(stmt, 7))
        }
        // 仅当该时间段完全没有事件覆盖时才用 session 数据（避免跨天会话历史混入）
        let coveredInRange = keys.intersection(covered)
        if coveredInRange.isEmpty {
            for (providerID, modelId, variant, sessions, miss, hit, output, reasoning) in sqlBreakdown {
                let modelKey = "\(providerID)/\(modelId)/\(variant)"
                let pricing = pricingLookup[modelKey] ?? .defaults(providerID: providerID, modelId: modelId, variant: variant)
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
```

`fetchCostSummary`（原 293-341 行）改为调用新 `fetchModelCostBreakdown`：

```swift
    func fetchCostSummary(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, pricingRules: [ModelPricingRule] = [], referenceDate: Date = .now) throws -> CostSummary {
        let breakdown = try fetchModelCostBreakdown(
            year: year, month: month, day: day,
            from: startDate, to: endDate,
            pricingRules: pricingRules,
            referenceDate: referenceDate
        )
        return CostSummary.from(breakdown: breakdown)
    }
```

> 需确认 `CostSummary.from(breakdown:)` 存在（原代码第 139 行用了 `CostSummary.from(breakdown:)`，存在）。

- [ ] **Step 4: 改写 `fetchAgentUsage` 与 `fetchProjectUsage`**

`fetchAgentUsage`（原 383-413 行）改为事件优先：

```swift
    func fetchAgentUsage(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> [AgentUsage] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        var map: [String: AgentUsage] = [:]
        for (dateKey, agents) in TokenDeltaTracker.shared.agentConsumption where keys.contains(dateKey) {
            for (agent, tokens) in agents {
                let costs = TokenDeltaTracker.shared.agentCostConsumption[dateKey]?[agent] ?? 0
                let existing = map[agent]
                map[agent] = AgentUsage(
                    agentName: agent,
                    sessions: (existing?.sessions ?? 0) + 1,
                    inputTokens: (existing?.inputTokens ?? 0) + tokens.tokensInput,
                    outputTokens: (existing?.outputTokens ?? 0) + tokens.tokensOutput,
                    reasoningTokens: (existing?.reasoningTokens ?? 0) + tokens.tokensReasoning,
                    cacheReadTokens: (existing?.cacheReadTokens ?? 0) + tokens.tokensCacheRead,
                    totalTokens: (existing?.totalTokens ?? 0) + tokens.total,
                    cost: (existing?.cost ?? 0) + costs
                )
            }
        }
        let coveredInRange = keys.intersection(covered)
        if coveredInRange.isEmpty {
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
                \(buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).0)
                GROUP BY agent
                ORDER BY COUNT(*) DESC
                """,
                parameters: buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).1
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
            for item in sql {
                map[item.agentName] = item
            }
        }
        return map.values.sorted { $0.sessions > $1.sessions }
    }
```

`fetchProjectUsage`（原 415-451 行）改为（事件优先 + project 名称 JOIN 兜底）：

```swift
    func fetchProjectUsage(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> [ProjectUsage] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        var map: [String: ProjectUsage] = [:]
        for (dateKey, projects) in TokenDeltaTracker.shared.projectConsumption where keys.contains(dateKey) {
            for (projectID, tokens) in projects {
                let costs = TokenDeltaTracker.shared.projectCostConsumption[dateKey]?[projectID] ?? 0
                let existing = map[projectID]
                map[projectID] = ProjectUsage(
                    projectId: projectID,
                    projectName: existing?.projectName ?? "",
                    worktree: existing?.worktree ?? "/",
                    sessions: (existing?.sessions ?? 0) + 1,
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
                if var item = map[row.id] {
                    item.projectName = row.name
                    item.worktree = row.worktree
                    map[row.id] = item
                }
            }
        }
        let coveredInRange = keys.intersection(covered)
        if coveredInRange.isEmpty {
            let (rawWhere, params) = buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate)
            let whereClause = rawWhere.isEmpty ? "" : rawWhere.replacingOccurrences(of: "time_created", with: "s.time_created")
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
            for item in sql {
                map[item.projectId] = item
            }
        }
        return map.values.sorted { $0.sessions > $1.sessions }
    }
```

- [ ] **Step 5: 改写 `fetchEfficiencySummary` 与 `fetchEfficiencyDetail`**

`fetchEfficiencySummary`（原 453-475 行）改为：

```swift
    func fetchEfficiencySummary(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil) throws -> ProductivitySummary {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)
        if !coveredInRange.isEmpty {
            var sum = SummaryData.zero
            var sessionCount = 0
            for (dateKey, s) in TokenDeltaTracker.shared.dailySummary where keys.contains(dateKey) {
                sum += s
                if s.total > 0 { sessionCount += 1 }
            }
            var totalTokens = TokenData.zero
            for (dateKey, tokens) in TokenDeltaTracker.shared.dailyConsumption where keys.contains(dateKey) {
                totalTokens += tokens
            }
            return ProductivitySummary(
                totalAdditions: sum.additions,
                totalDeletions: sum.deletions,
                totalFiles: sum.files,
                sessionsWithChanges: sessionCount,
                totalTokens: totalTokens.total
            )
        }
        return try readOne(
            """
            SELECT COALESCE(SUM(summary_additions), 0),
                   COALESCE(SUM(summary_deletions), 0),
                   COALESCE(SUM(summary_files), 0),
                   COUNT(*),
                   COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write), 0)
            FROM \(sessionSource)
            \(buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).0)
            """,
            parameters: buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).1
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
```

`fetchEfficiencyDetail`（原 477-513 行）改为（事件优先 + 兜底）：

```swift
    func fetchEfficiencyDetail(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, limit: Int = 100, offset: Int = 0) throws -> [SessionEfficiency] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)
        if !coveredInRange.isEmpty {
            // 事件时间口径：时间段内有活动且产生变更量的会话，显示增量
            let deltas = TokenDeltaTracker.shared.sessionDelta(in: coveredInRange)
            let activeIDs = deltas.keys.filter { deltas[$0]?.summary.total ?? 0 > 0 }
            guard !activeIDs.isEmpty else { return [] }
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
            var result: [SessionEfficiency] = []
            for row in rows {
                guard let delta = deltas[row.id] else { continue }
                result.append(SessionEfficiency(
                    id: row.id,
                    title: row.title,
                    providerID: row.providerID,
                    modelId: row.modelId,
                    agent: row.agent,
                    additions: delta.summary.additions,
                    deletions: delta.summary.deletions,
                    files: delta.summary.files,
                    totalTokens: delta.totalTokens
                ))
            }
            return result
        }
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
            FROM \(sessionSourceAlias)
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
```

- [ ] **Step 6: 改写 `fetchSessions`（原 343-379 行）**

```swift
    func fetchSessions(year: String? = nil, month: String? = nil, day: String? = nil, from startDate: Date? = nil, to endDate: Date? = nil, limit: Int = 100, offset: Int = 0) throws -> [Session] {
        let covered = TokenDeltaTracker.shared.coveredDateKeys()
        let keys = dateKeys(year: year, month: month, day: day, from: startDate, to: endDate)
        let coveredInRange = keys.intersection(covered)
        if !coveredInRange.isEmpty {
            // 事件时间口径：时间段内有活动的会话 + 增量值
            let activeIDs = TokenDeltaTracker.shared.activeSessionIDs(in: coveredInRange)
            guard !activeIDs.isEmpty else { return [] }
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
            var result: [Session] = []
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
            }
            return result
        }
        return try readAll(
            """
            SELECT id, slug, title,
                   tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write,
                   cost, model, time_created,
                   json_extract(metadata, '$.project') AS project
            FROM \(sessionSource)
            \(buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).0)
            ORDER BY time_created DESC
            LIMIT ? OFFSET ?
            """,
            parameters: buildTimeClause(year: year, month: month, day: day, from: startDate, to: endDate).1 + [Int64(limit), Int64(offset)]
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
```

- [ ] **Step 7: 改写 `fetchAvailablePeriods` 与 `fetchAvailableDays`（原 223-250 行）**

`fetchAvailablePeriods`：返回事件日期 ∪ session 日期（按年月去重排序）：

```swift
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
        let combined = Dictionary(uniqueKeysWithValues: (periods + sqlPeriods).map { ("\($0.year)/\($0.month)", $0) })
        return combined.values.sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    }
```

`fetchAvailableDays`：事件日期 ∪ session 日期（按日排序）：

```swift
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
```

- [ ] **Step 8: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: 提交**

```bash
git add token_check/Services/DatabaseService.swift
git commit -m "feat: DatabaseService 全部时间段统计改为事件时间优先、session 表兑底"
```

---

### Task 6: ViewModel 改造

**Files:**
- Modify: `token_check/ViewModels/DailyTrendViewModel.swift`
- Modify: `token_check/ViewModels/CostViewModel.swift`
- Modify: `token_check/ViewModels/StatsViewModel.swift`
- Modify: `token_check/ViewModels/SessionListViewModel.swift`
- Modify: `token_check/ViewModels/TokenViewModel.swift`

**Interfaces:**
- Consumes: Task 4/5 的新行为

- [ ] **Step 1: 各 ViewModel 的 load() 前确保 tracker 已 refresh**

`DailyTrendViewModel.load()`（第 115 行 `DatabaseService.loadQueue.addOperation {` 之后插入）：

```swift
            if let ds = DatabaseService.shared, let db = ds.db {
                TokenDeltaTracker.shared.refresh(db: db)
            }
```

`CostViewModel.load()`（第 56 行后）、`StatsViewModel.load()`（第 59 行后）、`SessionListViewModel.load()`（第 67 行后）同样插入。

- [ ] **Step 2: DailyTrendViewModel 移除自己的 merge（service 已统一）**

删除 `load()` 中第 159-163 行的 session 补充分支：

```swift
                // 补充 session 表数据，填补 event 表可能缺失的历史记录
                if let qs = queryStart, let qe = queryEnd {
                    let sessionData = try service.fetchDailyUsageByModel(from: qs, to: qe)
                    data = self.mergeDailyUsage(eventData: data, sessionData: sessionData)
                }
```

改为：

```swift
                // service 层已统一为事件优先 + session 兜底
                if let qs = queryStart, let qe = queryEnd {
                    data = try service.fetchDailyUsageByModel(from: qs, to: qe)
                }
```

同时删除 `mergeDailyUsage` 方法（不再使用）。

- [ ] **Step 3: CostViewModel 移除 max 合并逻辑**

删除 `load()` 中第 61 行 `let pricingLookup = ModelPricingStore.lookup(from: pricingRules)`、第 64 行 `let eventMc: [String: TokenData]`、第 89-134 行的双循环合并（`breakdownMap` 构造与 `for item in sessionBreakdown` 的 max 合并），改为直接：

```swift
                let breakdown = try service.fetchModelCostBreakdown(
                    year: self.selectedYear,
                    month: self.selectedMonth,
                    day: self.selectedDay,
                    from: self.filterMode == .range ? self.startDate : nil,
                    to: self.filterMode == .range ? self.endDate : nil,
                    pricingRules: pricingRules,
                    referenceDate: referenceDate
                )
```

删除原 `eventMc`、`breakdownMap`、`pricingLookup` 相关代码（保留 `rb`、`modelRb` 的取值用于第 142-164 行的 rollback 叠加段，该段逻辑不变）。`let sessionBreakdown: [ModelCostBreakdown]` 声明改为 `let breakdown: [ModelCostBreakdown]`，后续 `breakdown.values...` 引用（第 135-140 行）改为 `breakdown.filter { $0.pricing.isEnabled }` 直接使用。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add token_check/ViewModels/DailyTrendViewModel.swift token_check/ViewModels/CostViewModel.swift token_check/ViewModels/StatsViewModel.swift token_check/ViewModels/SessionListViewModel.swift
git commit -m "feat: ViewModel 统一在加载前刷新 tracker，移除过时的 max/merge 合并逻辑"
```

---

### Task 7: 端到端验证

**Files:** 无（验证任务）

- [ ] **Step 1: 完整构建**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: 运行 App 并观察 widget 数据**

Run: `open /Users/langqin/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/token_check.app`（或 `open` 刚构建的 app）
等待约 2 分钟（TokenViewModel 每 60s 刷新 + 写 widget_data.json）。

- [ ] **Step 3: 校验 widget_data.json 口径一致**

```bash
python3 -c "
import json
with open('/Users/langqin/Library/Group Containers/group.com.luoyun.tokencheck/widget_data.json') as f:
    usage = json.load(f)['todayUsage']
total = usage['totalTokens']
hourly = sum(h['totalTokens'] for h in usage['hourlyTokens'])
print('totalTokens(左上角):', total)
print('hourlyTokens 合计(分时):', hourly)
print('差值:', total - hourly)
"
```

Expected: 差值应为 0（今天有跨天会话时，两者都应包含其今日增量；若 event 数据覆盖今天则必为 0；若兜底路径生效，差值可能为跨天会话今日增量，需人工判断）。

- [ ] **Step 4: 校验热力图与每日数据**

打开 App 的"每日趋势"页（默认近7天），与 widget 近7天柱状图对比同一天数值应一致（都按事件时间）。打开"统计"页的 Agent/项目/效率，确认显示的数据为事件时间增量口径。

- [ ] **Step 5: 检查日志无异常**

Run: `log show --last 10m --predicate 'subsystem == "com.luoyun.tokencheck"' --style compact | grep -i "error"` 
Expected: 无新增 ERROR（token_check_debug.log 同查）

- [ ] **Step 6: 提交（如有修复）**

```bash
git add -A
git commit -m "fix: 端到端验证修复"
```

---

## Self-Review 记录

- **Spec 覆盖**：设计文档第 1 层（tracker 扩展）→ Task 2/3；第 2 层（Widget 链路）→ Task 4；第 3 层（App 统计链路）→ Task 5/6；第 4 层（列表展示）→ Task 5 Step 6 + Task 6；验证方式 → Task 7
- **已知偏差**：`fetchDailyUsage`（无调用者）不改；`fetchCostSummary` 通过重写为调用 `fetchModelCostBreakdown` 实现（原实现依赖 SQL 内部算价，新实现复用同一函数，语义一致）；CostViewModel 的 rollback 叠加逻辑保留；`fetchAgentUsage` 事件分支的 `sessions` 字段表示"活跃天数"（事件无会话数信息）
- **类型一致性**：`SummaryData`/`SessionDelta`/`RollbackRecord` 在 Task 1 定义，Task 2-6 引用同名同签名；`sessionRollbacks` 类型变更为 `[String: RollbackRecord]`、`pendingRollbacks` 变更为 `[String: SessionDelta]` 在 Task 2 完成，SessionListView 的 `.asTokenData` 用法同步；热力图结构（MonthlyHeatmapData/YearlyHeatmapData）无 cost 字段，仅覆盖 token 值
- **自审修正记录**：修正了 revert 结算时回滚前 cost/summary 未保存的问题（改用 SessionDelta 快照）；修正了 fetchDailyUsageByModel 兜底 SQL 在 year/month/day 模式下的参数错误（改用 buildTimeClause）；补全了 fetchProjectUsage/fetchEfficiencyDetail 完整代码；消除了占位描述
