# 冷启动性能优化方案对比（方案 X vs 方案 Y）

> **For agentic workers:** 本文是**选型决策文档**（不是实现计划）。用户看完选一个方向后，再按选定方向产出正式可执行计划（`writing-plans`）。当前文档用于在三选一前把关键事实、改动点、风险、取舍讲清楚。

**Goal:** 让 token_check 冷启动后主窗口"费用"页从约 15 秒延迟降低到秒级/毫秒级。

**Date:** 2026-08-25
**Status:** 决策待定

---

## 一、根因（已用日志与实测确证）

冷启动主窗口"费用"页慢的直接原因，已在运行日志中确证：

```
TokenDeltaTracker: 8163.3ms     ← 主瓶颈，约 8.2 秒
fetchTodayUsage: 820.2ms
Total refresh: 9683.1ms          ← TokenViewModel.refresh 总耗时约 9.7 秒
```

**关键事实：**

1. `TokenDeltaTracker.refresh()` 每次冷启动会**全量重放 32,038 条 `session.updated.1` 事件**（`lastProcessedRowId` 是进程内单例，冷启动归零），逐条 JSON 解析 + 更新约 20 个聚合字典 → **约 8.2 秒**（纯 CPU）。
2. 费页自身数据**极快**：对 `session` 表（仅 1,981 行）的 SQL 实测 `<10ms`。
3. `DatabaseService.loadQueue` 是**串行队列**（`maxConcurrentOperationCount = 1`）。
   - 任务 A = `TokenViewModel.refresh()`（9.7 秒聚合）先入队
   - 任务 B = `CostViewModel.load()`（费页数据，本身毫秒级）排在其后
   - 费页 UI 必须等 B 执行 → 被 A 的 9.7 秒硬挡，叠加后续 ≈ 15 秒。

> 备注：先前的方案 A（SQL 下推 `type='session.updated.1'`）已生效（安装版二进制已确认包含），它把 event 读表 I/O 从约 3.05GB 降到约 18MB，但**无法减少 3.2 万条 JSON 的 CPU 解析循环**，因此对冷启动耗时几乎没有改善——这正是"改了没变化"的原因。

**一句话：费页不慢，是被串行队列上 9.7 秒的聚合任务排队堵住了。**

---

## 二、方案 X：解耦费页加载（推荐）

### 核心思路

让"费用"页的数据加载**不再被 `TokenViewModel.refresh()` 的后台聚合（9.7 秒）阻塞**。费页数据改为主要来自 `session` 表的直接 SQL 聚合（毫秒级），独立异步执行；`TokenDeltaTracker` 的 event 聚合继续在后台跑，只服务 Widget/菜单栏，不再排队挡住费页。

### 需要改动的文件

| 文件 | 改动 |
|---|---|
| `token_check/ViewModels/CostViewModel.swift` | ① `fetchOpencodeData()` 去掉对 `TokenDeltaTracker.shared.refresh(db:)` 的调用；② 数据来源改为 `DatabaseService` 的 session 表口径聚合；③ `load` 后不再走后端串行 `loadQueue` |
| `token_check/ViewModels/CostViewModel.swift` | 增加一个**独立的异步加载通道**（`DispatchQueue.global(qos: .userInitiated)` 或专用并行队列），与 `DatabaseService.loadQueue` 解耦 |
| `token_check/Services/TokenDeltaTracker.swift` | 给 `refresh()` 加**内置串行锁**（`NSRecursiveLock` 或专用串行队列），保证即使多个调用方（TokenViewModel / CostViewModel 若仍调）并发也不会互相覆盖 —— 防御性改动 |
| `token_check/Services/DatabaseService.swift` | 视情况：新增一个 `costQueue`（并行）供 CostViewModel 使用，避免与聚合的 `loadQueue` 混用 |

### 数据来源（口径）说明 —— 这是唯一需要你拍板的取舍

`fetchOpencodeData()` 目前是 **event 口径优先 + session 表兜底**。方案 X 把它改为**主用 session 表口径**。差异在：

- **session 表`SUM`聚合**：每行是会话当前累计值，按模型/Agent/项目 `SUM` 即得"截至当前"的准确总量、费用、会话数。**速度快（毫秒级）**。
- **event 口径**的价值：
  1. 跨午夜边界时把增量归属到正确日期（主要是"今日/某天"视图更准）
  2. 回滚账本（`hasRollback` / `rollbackTotal` 显示）

**取舍选项：**
- **Xa（推荐）**：费页**首屏用 session 表 SQL 立即显示**（毫秒级）；`TokenDeltaTracker` 的 event 聚合在后台完成后，**异步回填**回滚与高精度数据（通过 Combine/Notification 触发二次刷新）。首屏快 + 最终口径仍准。实现略多一步（UI 双阶段）。
- **Xb（最简）**：费页完全用 session 表口径，**放弃回滚显示**（`hasRollback` 恒 false）。改动最小，但若你在意回滚显示，此选项不可取。

### 关键代码草稿（以 Xa 为例）

**CostViewModel 新增独立加载通道 + session 口径：**

```swift
// CostViewModel.swift
private let costQueue = DispatchQueue(label: "com.luoyun.tokencheck.cost", qos: .userInitiated)

func load() {
    isLoading = true
    error = nil
    costQueue.async { [weak self] in
        guard let self else { return }
        // 不再进入 DatabaseService.loadQueue，不再触发 TokenDeltaTracker.refresh
        do {
            let data = try self.fetchOpencodeData()   // 改成 session 表口径
            DispatchQueue.main.async {
                self.periods = data.periods
                self.summary = CostSummary.from(breakdown: data.breakdown)
                self.modelBreakdown = data.breakdown
                self.pricingDescription = data.pricingDescription
                self.availableDays = ["全部"] + data.days
                self.isLoading = false
                self.costQueue... // (可选) 触发 tracker 二次回填
            }
        } catch {
            DispatchQueue.main.async {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}
```

`fetchOpencodeData()`：删除开头的 `TokenDeltaTracker.shared.refresh(db:)`，`breakdown` 改用 `service.fetchModelCostBreakdown(...)`（它内部已含"event 兜底 + session 表兜底"，event 部分读 @Atomic 聚合、极快）。这样即使 event 聚合未完成，session 表兜底也能给出完整结果。

```swift
// 移除：
// if let ds = DatabaseService.shared, let db = ds.db { TokenDeltaTracker.shared.refresh(db: db) }
```

**TokenDeltaTracker 内置串行锁（防御性）：**

```swift
// TokenDeltaTracker.swift
private let refreshLock = NSRecursiveLock()
func refresh(db: OpaquePointer) {
    refreshLock.lock(); defer { refreshLock.unlock() }
    // ... 原逻辑
}
```

### 预期效果

- 冷启动"费用"页：**约 15 秒 → 毫秒级**（session 表 SQL 聚合 + async 通道）。
- `TokenViewModel.refresh()` 的 9.7 秒聚合**不再挡费页**；它继续在后台为菜单栏/Widget 服务。
- 数据口径：Xa 方案下首屏用 session 表、随 tracker 完成回填高精度，最终一致；Xb 方案下预算消失回滚。

### 风险

- 需要处理 `fetchModelCostBreakdown` 在 event 聚合未完成时的正确性 → 由"event 未覆盖则 session 表兜底"逻辑保证（已有）。
- Xa 的双阶段刷新需要让 UI 在 tracker 更新后刷新一次（复用 `NotificationCenter.publisher(for: ...)` 或 `onChange`）。
- 改动集中在 `CostViewModel` + `DatabaseService`/`TokenDeltaTracker` 一处防御锁，低风险。

---

## 三、方案 Y：持久化聚合状态（治本，但改动大）

### 核心思路

`TokenDeltaTracker` 的聚合状态（约 20 个字典，3.2 万 session 的累计）**跨进程持久化到磁盘**。冷启动从磁盘恢复状态 + `lastProcessedRowId`，只增理新增 event → `refresh()` 从 8 秒降到增量秒级，**冷启动整体**都变快（不止费页，菜单栏/Widget 也快）。

### 需要改动的文件

| 文件 | 改动 |
|---|---|
| `token_check/Services/TokenDeltaTracker.swift` | 定义状态快照结构（Codable）；`refresh()` 完成后序列化落盘；冷启动先反序列化恢复状态 + `lastProcessedRowId` |
| 新增持久化位置 | App 容器或 `group.com.luoyun.tokencheck` 的共享目录 |

### 关键难点（这是为什么把它列为备选）

1. **状态巨大**：`dailyConsumption` / `dailyModelConsumption` / `sessionDailyDelta` / `sessionTokenCache` / `sessionActiveDays` / rollback 账本…… 合计可能数十 MB。用 JSON 序列化/反序列化成本高（数十 MB 的 JSON 解析可能 1-3 秒），且**每次 refresh 后都要写盘**（每 5 分钟定时器）会带来持续 I/O 和卡顿。
2. **增理正确性**：跨进程恢复后，增量逻辑必须与"假设从头重放"完全一致，否则数字漂移。需要先持久化**全部**状态字典才能保证，缺少任何一个都会出错。
3. **数据库被替换/重置**（opencode 数据库 rebuild、rowid 归零）时，持久化的 `lastProcessedRowId` 可能大于新的 `MAX(rowid)` → 需检测并回退全量重放。
4. **冷启动读盘的收益不确定**：反序列化耗时可能抵掉重放节省的时间，尤其在状态大时。

### 结论

方案 Y **无法保证明显优于 X**，且工程复杂度、数据一致性风险显著更高。**不推荐**作为本轮改动。仅当未来 event 规模持续膨胀、且 Xa 的"首屏 session 口径 + 后台回填"仍不满足时，才考虑做。

---

## 四、对比矩阵

| 维度 | 方案 X（解耦费页） | 方案 Y（持久化聚合） |
|---|---|---|
| 冷启动费页耗时 | 15 秒 → **毫秒级** | 15 秒 → 秒级（受序列化成本限制） |
| 改动范围 | 小（CostViewModel + 防御锁） | 大（TokenDeltaTracker 重构 + 落盘） |
| 数据口径 | Xa：首屏 session + 后台回填；Xb：纯 session（丢回滚） | 不变（保持 event 口径） |
| 数据一致性风险 | 低 | 高（增量恢复可能漂移） |
| 写盘/IO 压力 | 无 | 每次 refresh 都写（5 分钟/次） |
| 其它界面（菜单栏/Widget）提速 | 无（仍 9.7 秒后更新） | 有 |
| 立即见效 | ✓ | 视序列化成本 |

---

## 五、推荐

**方案 X（推荐 Xa）**：改动小、立即让费页毫秒级显示、不改变最终数据口径；唯一的取舍是首屏先显示 session 表口径、tracker 完成后回填。

如果用户能接受"冷启动时菜单栏/Widget 仍要 ~9.7 秒后才有数"（这两者非用户交互首屏，通常可接受）——方案 X 足矣。

---

## 六、验证方式（选定后执行）

1. `xcodebuild -project token_check.xcodeproj -scheme token_check build`（编译通过）
2. 安装到 `/Applications`（让用户实测的版本真的包含改动）：
   ```bash
   xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Release -derivedDataPath /tmp/tc-rel build
   cp -R /tmp/tc-rel/Build/Products/Release/token_check.app /Applications/
   ```
3. 冷启动实测：
   ```bash
   open -a /Applications/token_check.app
   /usr/bin/log show --last 2m --predicate 'subsystem == "com.luoyun.tokencheck"' --style compact | grep -iE "TokenDeltaTracker|Total refresh|ms"
   ```
   期望：`TokenDeltaTracker` 不再出现在费页等待路径；费页从点击到显示数据约毫秒级。
4. 手动核对"费用"页数字与改动前趋势一致（重点：本月/今日总费用）。

---

## 决策待办

- [ ] 用户选定方案：**Xa** / **Xb** / Y
- [ ] 选定后由 `writing-plans` 产出对应正式实现计划（逐任务、含测试）
