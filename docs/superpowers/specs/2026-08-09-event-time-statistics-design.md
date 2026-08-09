# 全项目统一"事件时间"统计口径设计

日期：2026-08-09
状态：已批准（用户确认）

## 背景与问题

大号小组件中，最左上角显示的 token 总数与"当天分时"栏最右侧显示的 token 合计数值不一致。

### 根因

两处数值使用了不同的统计口径：

| 位置 | 数据 | 口径 |
|------|------|------|
| 左上角 totalTokens | `fetchTodayUsage.totalTokens` | 按**会话创建时间**（`session.time_created > 今日零点`）SQL 聚合，只算今天新建的会话 |
| 分时栏合计 | `hourlyTokens` 求和 | 按**事件发生时间**（`event.info.time.updated`）由 TokenDeltaTracker 累计增量 delta，包含跨天会话今天的增量 |

实测（2026-08-09 08:50 widget_data.json）：`totalTokens = 2,014,651`，`hourlyTokens 合计 = 2,181,077`，差异 166,426。经查证：昨晚 17:54 创建的会话 `ses_01f33f14` 今早继续使用产生了 166,426 token 增量，被计入分时图（事件时间在今天），但因其创建时间是昨天，未被计入 totalTokens（SQL 按 time_created 过滤）。两者差恰好等于 166,426，根因确认。

### 目标

全项目所有时间段统计统一按**事件发生时间**（`event.info.time.updated`）归属时间段：
- 今天产生的消耗就统计在今天，跨天会话不得把历史牵扯到今天
- 也不得把今天的消耗归属到会话创建的那一天

## 现状盘点（所有时间段统计点）

### Widget 链路（WidgetDataService.swift）

| 统计 | 当前口径 | 数据源 |
|------|---------|-------|
| totalTokens（左上角） | 会话创建时间 | session 表 |
| input/output/cacheRead/reasoning/cacheWrite | 会话创建时间 | session 表 |
| todayCost | 会话创建时间 | session 表 |
| sessionCount / messageCount / projectCount | 会话/消息创建时间 | session/message 表 |
| additions / deletions / files | 会话创建时间 | session 表 |
| dailyTokens（近7天/30天柱状图） | 会话创建时间归日 | session 表 |
| hourlyTokens（分时图） | ✅ 事件时间 | event 表 delta |
| 月度热力图（fetchMonthData） | 会话创建时间归日 | session 表 |
| 年度热力图（fetchYearlyData） | 会话创建时间归日 | session 表 |

### App 内统计（DatabaseService.swift + ViewModels）

| 统计 | 当前口径 | 数据源 |
|------|---------|-------|
| fetchDailyUsage / fetchDailyUsageByModel（趋势图） | session 优先、事件只补缺 | 混合（DailyTrendViewModel.mergeDailyUsage） |
| fetchModelCostBreakdown / fetchCostSummary（费用页） | session + 事件 **max** 合并（错误） | 混合（CostViewModel） |
| fetchAgentUsage / fetchProjectUsage（统计页） | 会话创建时间 | session 表 |
| fetchEfficiencySummary / fetchEfficiencyDetail（效率） | 会话创建时间 | session 表 |
| fetchSessions（会话列表） | 会话创建时间 | session 表 |
| fetchAvailablePeriods / fetchAvailableDays | 会话创建时间 | session 表 |

### 正确性隐患

- CostViewModel 使用 `max(existing, item)` 合并事件与 session 数据：跨天会话的事件 delta 为 10k、session 累计值为 50k 时，max 取 50k，把历史算进了当天
- DailyTrendViewModel 的 merge 中 session 数据优先，与用户诉求相反
- CostView/StatsView/DailyTrendView 的 load() 不先 refresh TokenDeltaTracker，App 刚启动时内存累计可能不完整

## 数据源事实（已验证）

- `event` 表 `session.updated.1` 事件 JSON 含：`info.tokens`（input/output/reasoning/cache.read/cache.write）、`info.cost`（累计值，需算 delta）、`info.summary`（additions/deletions/files，累计值，需算 delta）、`info.time.created/updated`、`info.agent`、`info.projectID`、`info.model`
- `event` 表最早事件时间 2026-06-25 20:41，`session` 表最早 2026-05-17 08:55 → event 表历史缺失约一个多月
- `event` 表有 `revert` 字段（rollback 语义），现有 tracker 已按"不扣减、记正数 rollback"处理
- 有两个数据库（opencode.db + deveco.db），tracker 分别处理并累计到同一套字典；session 聚合用 UNION ALL

## 设计方案

### 核心原则

1. **事件时间为主，session 表兜底**：所有时间段统计先读 TokenDeltaTracker（事件时间 delta），事件表覆盖不到的历史（2026-06-25 之前）用 session 表按 time_created 归日补齐
2. 今天的数据永远以事件时间为准
3. rollback（revert）语义沿用现有"不扣减、记正数 rollback"，新增维度同步处理

### 第 1 层：TokenDeltaTracker 扩展为统一统计引擎

在现有 `dailyConsumption` / `hourlyConsumption` / `dailyModelConsumption` 之外，事件处理时同步解析并 delta 化：

| 新增字段 | 类型 | 说明 |
|---------|------|------|
| `sessionCostCache` | `[String: Double]` | 每会话最近 cost（算 delta 用） |
| `sessionSummaryCache` | `[String: SummaryData]` | 每会话最近 additions/deletions/files（算 delta 用） |
| `dailyCostConsumption` | `[String: Double]` | 每日成本（key: yyyy-MM-dd） |
| `hourlyCostConsumption` | `[String: Double]` | 每小时成本（key: yyyy-MM-dd/HH） |
| `modelCostConsumption` | `[String: [String: Double]]` | 每日按模型成本 |
| `dailySummary` | `[String: SummaryData]` | 每日变更量 delta |
| `sessionDailyDelta` | `[String: [String: SessionDelta]]` | 按会话维度的当日增量（tokens+cost+summary） |
| `sessionActiveDays` | `[String: Set<String>]` | 会话活跃日期集合 |
| `dailyActiveSessions` | `[String: Int]` | 每日活跃会话数 |
| `dailyActiveProjects` | `[String: Set<String>]` | 每日活跃项目数 |
| `agentConsumption` | `[String: [String: TokenData]]` | 每日按 Agent 的 token 增量 |
| `projectConsumption` | `[String: [String: TokenData]]` | 每日按项目 ID 的 token 增量 |

事件处理逻辑（main 与 deveco 两份相同代码同步改）：
- 解析 `info.cost`、`info.summary`、`info.agent`、`info.projectID`
- 与 `sessionTokens` 同样的模式：首次遇到取完整值、之后取 delta（`max(0, cur - prev)`）
- revert 事件沿用现有分支：记 pendingRollbacks，后续正数 rollback，不扣减
- **rollback 的归属**：所有新增维度（cost/summary/agent/project/session 维度）与现有 tokens 一致——**不包含 rollback 正数**，rollback 单独记账。`RollbackRecord` 扩展 `cost`、`additions`、`deletions`、`files` 字段（默认 0），`dailyRollbacks` / `sessionRollbacks` 复用，UI 层按现有模式叠加（如 `adjTotal = total + rb.total`）
- 新增查询 API：`consumptionCost(...)`、`sessionDelta(...)`、`activeSessions(in:)` 等，与现有 `consumption(...)` 风格一致

### 第 2 层：Widget 链路（WidgetDataService.swift）

`fetchTodayUsage`：
- `input/output/cacheRead/reasoning/cacheWrite/totalTokens`：优先 `dailyConsumption[todayKey]`，兜底 `fetchTodayRow` SQL
- `todayCost`：优先 `dailyCostConsumption[todayKey]`，兜底 `fetchTodayCost` SQL
- `sessionCount`：优先 `dailyActiveSessions[todayKey]`，兜底 SQL
- `projectCount`：优先 `dailyActiveProjects[todayKey].count`，兜底 SQL
- `messageCount`：保持 SQL（消息即时产生，time_created 即消息发生时间，口径天然正确）
- `additions/deletions/files`：优先 `dailySummary[todayKey]`，兜底 SQL
- `hourlyTokens`：不变（已是事件时间）
- `dailyTokens`：逐日取 `dailyConsumption`，6-25 前兜底 `fetchDailyTokens` SQL；`dailyCosts` 同样处理

`fetchMonthData` / `fetchYearlyData`：逐日取 `dailyConsumption` + `dailyCostConsumption`，事件表缺失的日期兜底现有 SQL，合并后输出。

### 第 3 层：App 内统计链路（DatabaseService.swift + ViewModels）

- `fetchDailyUsage` / `fetchDailyUsageByModel`：事件优先 + session 兜底（改为在 service 层统一合并，或反转 DailyTrendViewModel 的 merge 优先序）
- `fetchModelCostBreakdown` / `fetchCostSummary`：事件优先 + session 兜底，**移除 max 合并**
- `fetchAgentUsage` / `fetchProjectUsage`：事件优先（agentConsumption / projectConsumption），project 名映射查 project 表；6-25 前兜底现有 SQL
- `fetchEfficiencySummary` / `fetchEfficiencyDetail`：事件 summary delta 优先，兜底 SQL
- `fetchSessions`：按 `sessionActiveDays` 过滤"时间段内有活动的会话"，显示该时间段内的增量值（tokens/cost/summary）；兜底 SQL（6-25 前）
- `fetchAvailablePeriods` / `fetchAvailableDays`：事件日期 ∪ session 日期（兜底）
- `CostViewModel`：合并逻辑改为事件优先 + 兜底
- `DailyTrendViewModel`：merge 顺序反转（事件优先）
- 所有 ViewModel 的 `load()` 先确保 tracker 已 refresh（有 db 句柄时调用 `TokenDeltaTracker.shared.refresh(db:)`，含 deveco）

### 第 4 层：会话列表 / 效率明细展示

- 过滤：`sessionActiveDays` 中该时间段内活跃的会话
- 展示：`sessionDailyDelta` 中该时间段内的增量值
- 会话标题、模型名等静态信息仍从 session 表按 id 查询

## 已知边界（接受）

1. 2026-06-25 之前的历史走 session 兜底，口径不同但数据完整
2. 6-25 前创建、之后仍活跃的会话，tracker 首次遇到它时会把当时完整量计入首次出现那天（无法避免）
3. rollback 语义沿用现有逻辑

## 验证方式

1. 构建 `xcodebuild build` 通过
2. 实测 widget_data.json：`totalTokens == hourlyTokens 合计`（今天无跨天边界时）或差值等于跨天会话今日 delta
3. 手动验证一个跨天会话：昨天创建、今天继续使用的会话，其今日增量计入今天所有统计
4. 检查 App 内趋势图、费用页、统计页、会话列表数据与 widget 一致
