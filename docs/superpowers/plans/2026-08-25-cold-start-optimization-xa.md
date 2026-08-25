# 冷启动优化（方案 Xa）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 token_check 冷启动后"费用"页从约 15 秒降到毫秒级——把费页数据加载移出会被 9.7 秒聚合任务阻塞的串行 `loadQueue`，并让 `TokenDeltaTracker` 后台聚合完成后异步回填高精度/回滚数据。

**Architecture:** 费页数据改走独立的 `costQueue`（并行，`DispatchQueue.async`），不再进入 `DatabaseService.loadQueue` 串行队列；`CostViewModel.fetchOpencodeData()` 去掉对 `TokenDeltaTracker.shared.refresh(db:)` 的触发（该 8 秒全量重放由 AppDelegate 的 `TokenViewModel` 独占后台执行）；`TokenViewModel.refresh()` 完成后广播 `SharedStorage.tokenAggregationUpdated`，`CostViewModel` 收到后**静默**二次加载，用最新聚合回填高精度/回滚。首屏（session 表口径）毫秒级，回填（event 口径）在聚合完成后到达。

**Tech Stack:** Swift / SwiftUI / SQLite3 / Combine / OSLog / xcodebuild

**Spec:** `docs/superpowers/plans/2026-08-25-cold-start-optimization.md`（选型决策依据）

## Global Constraints

- 全部代码注释使用中文（AGENTS.md 要求）；回复一律中文。
- **不得改动** widget `kind`、chronod 清理逻辑（AGENTS.md 教训：改 kind 会引发通知中心卡顿）。
- **不得**使用 `as any`/`@ts-ignore`（Swift 无此类，但禁止用 `as!` 强转、`try!` 抑制错误）。
- 不新增第三方依赖；不新增测试 target（项目现有 scheme 为 TodayWidget/token_check/token_checkWidget，无 XCTest case；本计划以**编译通过 + 冷启动实测 + 手动核对**为验证标准）。
- 现有 SQL/查询方法、`DatabaseService`、`CostSummary/ModelCostBreakdown` 等类型签名保持不变，只改调度与触发时机。
- 改动必须**退回可得**：每 Task 独立可编译，避免一次大改。

---

## File Structure

| 文件 | 职责 | 改动 |
|---|---|---|
| `token_check/Services/SharedStorage.swift` | 集中存放 Notification.Name 常量 | 新增 `tokenAggregationUpdated` |
| `token_check/ViewModels/TokenViewModel.swift` | 后台聚合刷新（AppDelegate 独占） | `refresh()` 完成后广播通知 |
| `token_check/ViewModels/CostViewModel.swift` | 费页数据加载 | ① 独立 `costQueue`；② 去掉 refresh 触发；③ 静默回填 |

---

### Task 1: 新增聚合完成通知常量

**Files:**
- Modify: `token_check/Services/SharedStorage.swift:6`

**Interfaces:**
- Produces: `SharedStorage.tokenAggregationUpdated: Notification.Name` — 供 TokenViewModel 广播、CostViewModel 订阅。

- [ ] **Step 1: 在 SharedStorage 增加通知常量**

```swift
final class SharedStorage {
    static let store = SharedStorage()

    static let pricingRulesUpdated = Notification.Name("com.luoyun.tokencheck.pricingRulesUpdated")
    static let tokenAggregationUpdated = Notification.Name("com.luoyun.tokencheck.tokenAggregationUpdated")
    // ...
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add token_check/Services/SharedStorage.swift
git commit -m "feat: 新增 tokenAggregationUpdated 聚合完成通知常量"
```

---

### Task 2: TokenViewModel 聚合完成后广播

**Files:**
- Modify: `token_check/ViewModels/TokenViewModel.swift:258-278`（`refresh()` 主线程 UI 更新块）

**Interfaces:**
- Consumes: `SharedStorage.tokenAggregationUpdated`
- Produces: 在聚合完成并更新 `usage` 等主线程字段后，post 一次通知。

- [ ] **Step 1: 在 refresh() 成功更新 UI 后 post 通知**

在 `DispatchQueue.main.async { self.usage = result; ...; self.isLoading = false; ... }` 块的**末尾**追加：

```swift
// refresh 已完成一次聚合，通知费页进行静默回填（event 口径）
NotificationCenter.default.post(name: SharedStorage.tokenAggregationUpdated, object: nil)
```

(位置：紧接 `self.isLoading = false` 之后、`if apiKey.isEmpty { ... }` 之前或之后均可，但必须在 `usage` 已赋值的同一主线程块内。)

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add token_check/ViewModels/TokenViewModel.swift
git commit -m "feat: TokenViewModel 聚合完成后广播 tokenAggregationUpdated"
```

---

### Task 3: CostViewModel 增加独立异步通道

**Files:**
- Modify: `token_check/ViewModels/CostViewModel.swift:39-46`（init 区域）、`203-269`（`loadOpencode/loadDsh/loadAll`）

**Interfaces:**
- Consumes: 无新依赖（使用 `DispatchQueue`）
- Produces: `private let costQueue: DispatchQueue` — 供三个 `load*` 函数改用。

- [ ] **Step 1: 新增 costQueue 属性**

在 `CostViewModel` 的 `private let defaults = UserDefaults.standard` 附近新增：

```swift
private let costQueue = DispatchQueue(label: "com.luoyun.tokencheck.cost", qos: .userInitiated)
```

- [ ] **Step 2: 三个 load* 函数改用 costQueue**

将 `loadOpencode()`、`loadDsh()`、`loadAll()` 里的 `DatabaseService.loadQueue.addOperation { ... }` 全部替换为 `costQueue.async { ... }`。

以 `loadOpencode()` 为例（其余两个同理，只改队列名，回调体不动）：

```swift
private func loadOpencode() {
    costQueue.async { [weak self] in
        guard let self else { return }
        do {
            let data = try self.fetchOpencodeData()
            DispatchQueue.main.async {
                self.periods = data.periods
                self.summary = CostSummary.from(breakdown: data.breakdown)
                self.modelBreakdown = data.breakdown
                self.pricingDescription = data.pricingDescription
                self.availableDays = ["全部"] + data.days
                self.hasRollback = data.hasRollback
                self.rollbackTotal = data.rollbackTotal
                self.isLoading = false
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

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add token_check/ViewModels/CostViewModel.swift
git commit -m "feat: CostViewModel 改用独立 costQueue，与聚合 loadQueue 解耦"
```

---

### Task 4: 移除 cost 链路对聚合 refresh 的触发

**Files:**
- Modify: `token_check/ViewModels/CostViewModel.swift:86-90`（`fetchOpencodeData()` 开头）

**Interfaces:**
- Consumes: 无（删除调用）
- Produces: `fetchOpencodeData()` 不再触发 8 秒聚合；其内部读取 `TokenDeltaTracker` 的 @Atomic 聚合 + `DatabaseService` session 表兜底，均为毫秒级。

- [ ] **Step 1: 删除 fetchOpencodeData 开头的 refresh 调用**

删除这段（`guard let service = DatabaseService.shared` 之前）：

```swift
if let ds = DatabaseService.shared, let db = ds.db {
    TokenDeltaTracker.shared.refresh(db: db)
}
```

保留其余逻辑不变。注意：`fetchModelCostBreakdown` / `fetchAvailablePeriods` 内部已有"event 覆盖日期优先 + session 表未覆盖日期兜底"，因此即使 tracker 聚合尚未完成（covered 未含今日），费页首屏仍会从 session 表得到完整正确结果。

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add token_check/ViewModels/CostViewModel.swift
git commit -m "feat: fetchOpencodeData 不再触发聚合 refresh，改由 TokenViewModel 独占后台执行"
```

---

### Task 5: CostViewModel 静默回填（监听聚合完成）

**Files:**
- Modify: `token_check/ViewModels/CostViewModel.swift:43-46`（init）、`59-72`（load / 新增 reloadSilently）

**Interfaces:**
- Consumes: `SharedStorage.tokenAggregationUpdated`；`fetchOpencodeData()`
- Produces: 新私有方法 `private func reloadSilently()`（不设 isLoading、失败静默）；抽出 `private func applyOpencode(_ data: OpencodeCostData)` 供 `loadOpencode` 与 `reloadSilently` 复用。

- [ ] **Step 1: 抽出赋值逻辑，新增 reloadSilently**

在 `CostViewModel` 内新增或调整如下方法（`OpencodeCostData` 为 `fetchOpencodeData` 返回的 private struct）：

```swift
/// 统一把 opencode 数据应用到 UI（loadOpencode 与静默回填共用）
private func applyOpencode(_ data: OpencodeCostData) {
    self.periods = data.periods
    self.summary = CostSummary.from(breakdown: data.breakdown)
    self.modelBreakdown = data.breakdown
    self.pricingDescription = data.pricingDescription
    self.availableDays = ["全部"] + data.days
    self.hasRollback = data.hasRollback
    self.rollbackTotal = data.rollbackTotal
}

/// 聚合完成后静默回填：不设 isLoading、失败忽略，避免骨架屏闪烁
private func reloadSilently() {
    costQueue.async { [weak self] in
        guard let self else { return }
        do {
            let data = try self.fetchOpencodeData()
            DispatchQueue.main.async { self.applyOpencode(data) }
        } catch {
            // 静默：首屏已显示，回填失败不干扰用户
        }
    }
}
```

`loadOpencode()` 原内联赋值改为调用 `self.applyOpencode(data)`（`isLoading=false` 仍在 catch 与成功路径处理）。

- [ ] **Step 2: init 订阅、deinit 移除**

在 `init()` 末尾追加：

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleAggregationUpdated),
    name: SharedStorage.tokenAggregationUpdated,
    object: nil
)
```

新增：

```swift
@objc private func handleAggregationUpdated() {
    reloadSilently()
}

deinit {
    NotificationCenter.default.removeObserver(self)
}
```

> 注意：`CostViewModel` 需为 `@objc` 兼容——`NotificationCenter` selector 方式需要 `@objc`。若 `CostViewModel` 是 `final class` 且继承自 `NSObject` 才能做 selector target；当前它是 `class CostViewModel: ObservableObject`。因此**改用 block-based observer** 更稳妥：

```swift
private var aggregationObserver: NSObjectProtocol?

// init 内：
self.aggregationObserver = NotificationCenter.default.addObserver(
    forName: SharedStorage.tokenAggregationUpdated,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.reloadSilently()
}

// deinit：
if let aggregationObserver {
    NotificationCenter.default.removeObserver(aggregationObserver)
}
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
git add token_check/ViewModels/CostViewModel.swift
git commit -m "feat: 费页监听聚合完成通知，静默回填 event 口径/回滚数据"
```

---

### Task 6: 构建、安装与冷启动实测

**Files:**
- 无源码改动（仅验证）

**Interfaces:**
- Consumes: Task 1-5 全部改动

- [ ] **Step 1: Release 构建**

```bash
xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Release -derivedDataPath /tmp/tc-rel build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: 安装到 /Applications（确保实测版本真含改动）**

```bash
rm -rf /tmp/tc-rel/Build/Products/Release/token_check.app 2>/dev/null
cp -R /tmp/tc-rel/Build/Products/Release/token_check.app /Applications/
```

- [ ] **Step 3: 冷启动并抓取日志**

```bash
open -a /Applications/token_check.app
/usr/bin/log show --last 2m --predicate 'subsystem == "com.luoyun.tokencheck"' --style compact | grep -iE "TokenDeltaTracker|Total refresh|ms" | tail -20
```

**Success criteria：**
- [ ] 冷启动"费用"页从点击到显示数据**约毫秒级**（不再被 9.7 秒聚合排队阻塞）。
- [ ] `TokenDeltaTracker` 的聚合仍在后台完成（日志仍可见 `TokenDeltaTracker: ~8s` / `Total refresh: ~9.7s`），但**不再挡住费页**。
- [ ] 聚合完成后，费页数据被**静默回填**更新（event 口径/回滚），无骨架屏闪烁。

- [ ] **Step 4: 手动核对数字**

打开"费用"页，核对本月/今日总费用、模型分解与改动前趋势一致（首屏 session 口径与回填 event 口径可能短暂差异，最终应一致）。切到"统计"/"趋势"/"会话"页确认无回归。

---

## Self-Review

**Spec coverage：**
- 解耦费页加载（独立 costQueue）→ Task 3
- 移除触发 8 秒聚合 → Task 4
- 后台聚合完成异步回填（静默、无闪烁）→ Task 5
- 通知常量与广播 → Task 1、2
- 编译 + 实测 + 手动核对 → Task 6

**Placeholder scan：** 无"TBD/适当处理/相似于 N"等占位；每 Task 含真实代码与验证命令。

**Type consistency：**
- `SharedStorage.tokenAggregationUpdated` 在 Task 1 定义，Task 2 post、Task 5 订阅 —— 一致。
- `costQueue` 在 Task 3 定义，Task 3/5 使用 —— 一致。
- `applyOpencode(_ data: OpencodeCostData)` 在 Task 5 定义并复用 —— `OpencodeCostData` 为 `fetchOpencodeData` 现成返回类型，无需重定义。

**已知取舍（如实记录）：**
- 首屏为 session 表口径，聚合完成后回填 event 口径，若二者在"跨天归属/回滚"上不同，数字会一次性微调（Xa 特性，符合方案文档）。
- 菜单栏/Widget 数据仍要等后台聚合（约 9.7 秒）完成才有 —— 非本次范围，方案文档已注明可接受。
