# 订阅统计：剩余时长校准 + DSH 估算合并 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把订阅周期从「自然月扣费日」改为「输入总长+剩余时长校准并固化起点」，并把 DSH 侧 opencode-go 事件估算消耗并入订阅已用量。

**Architecture:** 三层改动——(1) `WidgetDataService` 重写订阅计算：固化周期起点存 UserDefaults，used = opencode.db 真实 cost + DSH 估算 cost；(2) `SettingsView` 表单改为总长/剩余输入并显示倒计时；(3) widget 端 `TodayUsage` 透传周期结束时间并在大组件进度条旁显示剩余时长。

**Tech Stack:** SwiftUI (macOS app) / WidgetKit / SQLite3 / DSH 事件日志（JSONL + zstd 解压）

## Global Constraints

- 存放 UserDefaults 一律用 App Group suite：`UserDefaults(suiteName: "group.com.luoyun.tokencheck")`
- 新键名：`subscriptionPeriodStart`（Double，毫秒时间戳，固化周期起点）、`subscriptionPeriodDurationDays`（Int，周期总长天数）。旧键 `subscriptionStartDay` 直接不再读取，不做迁移。
- DSH 估算只认 `event.providerID == "opencode-go"`，且仅当 `ds.isFull`（事件级数据可用）时计入，否则为 0。
- 估算公式固定为：`miss/1e6×inputMiss + cacheRead/1e6×cacheHit + output/1e6×output + reasoning/1e6×reasoning`（不含 cacheWrite）。
- 周期起点向下取整到小时：`floor(seconds / 3600) * 3600`。
- 校验规则：总长 ≥ 1 天；剩余小时 ∈ [0, 23]；剩余总小时 ≤ 周期总小时。
- 项目无单元测试 target，验证 = xcodebuild 编译 + swift 公式断言脚本 + 真实环境手工核对清单。

---

### Task 1: 订阅计算层重写（WidgetDataService + TokenViewModel）

**Files:**
- Modify: `token_check/Services/WidgetDataService.swift:37-90`（TodayUsage 加字段）、`:584-641`（订阅计算）
- Modify: `token_check/ViewModels/TokenViewModel.swift:265-285`（widgetUsage 构造透传 periodEnd）

**Interfaces:**
- Produces: `WidgetDataService.computeSubscriptionData() -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)?`（周期起点取 `subscriptionPeriodStart` 键，不再用扣费日推算）
- Produces: `WidgetDataService.fetchDshOpencodeGoEstimatedCost(startDateMs: Int64) -> Double`
- Produces: `TodayUsage` 新增字段 `subscriptionPeriodEnd: Double?`（毫秒时间戳，周期结束时刻）
- Consumes: `DshService.shared.loadDetailedData() -> DshDetailedResult`（`.success(ds)`、`ds.isFull`、`ds.events`、`ds.pricingRules`）、`ModelPricingStore.price(forModelId:variant:providerID:at:rules:)`

- [ ] **Step 1: TodayUsage 增加 `subscriptionPeriodEnd` 字段**

`token_check/Services/WidgetDataService.swift` 中 `struct TodayUsage`（当前 37-90 行）：

在 `let subscriptionUsed: Double?` 之后加一行声明：

```swift
    let subscriptionPeriodEnd: Double?
```

在 init 参数表 `subscriptionUsed: Double? = nil,` 之后加：

```swift
        subscriptionPeriodEnd: Double? = nil,
```

在 init 体内 `self.subscriptionUsed = subscriptionUsed` 之后加：

```swift
        self.subscriptionPeriodEnd = subscriptionPeriodEnd
```

（`TodayUsage` 的全部属性为 Codable 合成，Optional 字段自动 decodeIfPresent，向后兼容旧缓存文件。）

- [ ] **Step 2: 重写 `computeSubscriptionData()`**

替换 `token_check/Services/WidgetDataService.swift:586-603` 整个方法为：

```swift
    func computeSubscriptionData() -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)? {
        guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
              defaults.bool(forKey: "subscriptionEnabled") else { return nil }

        let startMs = defaults.double(forKey: "subscriptionPeriodStart")
        let durationDays = defaults.integer(forKey: "subscriptionPeriodDurationDays")
        let budget = defaults.double(forKey: "subscriptionBudget")
        guard startMs > 0, durationDays >= 1, budget > 0 else { return nil }

        let startDate = Date(timeIntervalSince1970: startMs / 1000)
        let periodEnd = startMs + Double(durationDays) * 86_400_000

        logger.debug("订阅: periodStart=\(ISO8601DateFormatter().string(from: startDate)) durationDays=\(durationDays) budget=\(budget)")

        let used = fetchOpenCodeGoCost(startDateMs: Int64(startMs))
                 + fetchDshOpencodeGoEstimatedCost(startDateMs: Int64(startMs))
        logger.debug("订阅已用: \(String(format: "%.2f", used)) / \(String(format: "%.0f", budget)) = \(String(format: "%.0f", used / budget * 100))% (含 DSH 估算)")

        return (used, budget, max(budget - used, 0), periodEnd)
    }
```

- [ ] **Step 3: 新增 `fetchDshOpencodeGoEstimatedCost`**

在 `fetchOpenCodeGoCost` 方法（当前 605-617 行）之后插入新方法：

```swift
    /// DSH 侧 opencode-go 事件消耗估算（DSH 不记录真实费用，按价格规则 × tokens）
    private func fetchDshOpencodeGoEstimatedCost(startDateMs: Int64) -> Double {
        guard case .success(let ds) = DshService.shared.loadDetailedData(), ds.isFull else { return 0 }
        let startDate = Date(timeIntervalSince1970: Double(startDateMs) / 1000)
        let rules = ds.pricingRules
        var total = 0.0
        for event in ds.events {
            guard event.providerID == "opencode-go", event.time >= startDate else { continue }
            let prices = ModelPricingStore.price(
                forModelId: event.modelId,
                variant: "default",
                providerID: event.providerID,
                at: event.time,
                rules: rules
            )
            total += Double(event.inputTokens) / 1_000_000 * prices.inputMiss
                   + Double(event.cacheReadTokens) / 1_000_000 * prices.cacheHit
                   + Double(event.outputTokens) / 1_000_000 * prices.output
                   + Double(event.reasoningTokens) / 1_000_000 * prices.reasoning
        }
        logger.debug("订阅 DSH 估算: \(String(format: "%.2f", total))")
        return total
    }
```

- [ ] **Step 4: 删除 `currentSubscriptionStartDate`**

删除 `token_check/Services/WidgetDataService.swift:619-641` 整个 `currentSubscriptionStartDate(startDay:)` 方法（含其上方注释分隔不影响）。

- [ ] **Step 5: TokenViewModel 透传 periodEnd**

`token_check/ViewModels/TokenViewModel.swift:281-284`，在 `subscriptionUsed: subscriptionData?.used,` 之后加一行：

```swift
                subscriptionPeriodEnd: subscriptionData?.periodEnd,
```

- [ ] **Step 6: 编译验证（主 app target）**

Run:
```bash
cd /Users/langqin/macapp/token_check && xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`（此 scheme 会连带编译 widget 扩展；若因签名/环境报错只出现在最后一行之外，检查是否因改动引入——改动引入的报错会在 WidgetDataService/TokenViewModel 相关行）。

- [ ] **Step 7: 周期推算公式断言脚本**

Run:
```bash
cd /Users/langqin/macapp/token_check && swift -e '
import Foundation
let durationDays = 30
let remainingDays = 12
let remainingHours = 3
let now = Date()
let totalHours = durationDays * 24
let remainingTotal = remainingDays * 24 + remainingHours
let start = now.addingTimeInterval(-Double(totalHours - remainingTotal) * 3600)
let startMs = (floor(start.timeIntervalSince1970 / 3600) * 3600) * 1000
let endMs = startMs + Double(durationDays) * 86_400_000
let remainMs = endMs - now.timeIntervalSince1970 * 1000
let hours = Int(remainMs / 3_600_000)
assert(startMs <= now.timeIntervalSince1970 * 1000 && endMs > startMs, "起点/终点关系错误")
assert(hours >= 0 && hours <= durationDays * 24, "剩余显示越界")
let shown = "\(hours / 24)天\(hours % 24)h"
print("周期起点(整点)=\(Int(startMs / 3_600_000)) 结束(整点)=\(Int(endMs / 3_600_000))")
print("剩余显示=\(shown)，偏移误差=\(abs(remainingTotal - hours))h（≤1h 即正确）")
assert(abs(remainingTotal - hours) <= 1, "推算与剩余输入差 >1h")
print("OK: 周期推算与倒计时一致")
'
```
Expected: 打印 `OK: 周期推算与倒计时一致`，无断言失败。

- [ ] **Step 8: Commit**

```bash
cd /Users/langqin/macapp/token_check && git add token_check/Services/WidgetDataService.swift token_check/ViewModels/TokenViewModel.swift && git commit -m "feat: 订阅周期改为剩余时长校准（固化起点+DSH 估算并入）"
```

---

### Task 2: 设置页订阅表单改造

**Files:**
- Modify: `token_check/Views/SettingsView.swift:20-22`（AppStorage 声明）、`:283-347`（订阅 Section）

**Interfaces:**
- Consumes: UserDefaults 键 `subscriptionPeriodStart`（Double 毫秒）、`subscriptionPeriodDurationDays`（Int）
- Produces: 三处校验失败时的用户提示文案；`formattedPeriodStart` / `formattedRemaining` 显示

- [ ] **Step 1: AppStorage 声明替换**

将 `token_check/Views/SettingsView.swift:20-22` 三段替换为：

```swift
    @AppStorage("subscriptionEnabled", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionEnabled = false
    @AppStorage("subscriptionPeriodStart", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionPeriodStart = 0.0
    @AppStorage("subscriptionPeriodDurationDays", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionPeriodDurationDays = 30
    @AppStorage("subscriptionBudget", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionBudget = 60.0
```

- [ ] **Step 2: 新增临时输入 state 与倒计时刷新器**

在 `SettingsView.swift` 第 22 行（`subscriptionBudget` 声明）之后插入：

```swift

    @State private var periodRemainingDays = 10
    @State private var periodRemainingHours = 0
    @State private var subscriptionPeriodError: String?
    @State private var now = Date()
```

- [ ] **Step 3: 替换订阅 Section 中「扣费日 + 月度额度」两块**

将 `token_check/Views/SettingsView.swift:300-344`（从 `if subscriptionEnabled {` 到其闭合 `}`，即扣费日块 + 月度额度块整体）替换为（周期输入与月度额度并入同一 VStack，`if` 块以末尾 `}` 自行闭合）：

```swift
                if subscriptionEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar.day.fill")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("周期总长")
                                    .font(.subheadline.weight(.medium))
                                Text("订阅周期总天数（如 30 天滚动）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("", value: $subscriptionPeriodDurationDays, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                                .frame(width: 60)
                            Text("天")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "hourglass")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("当前剩余")
                                    .font(.subheadline.weight(.medium))
                                Text("对照官方控制台输入剩余时长，保存后校准周期起点")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("", value: $periodRemainingDays, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                                .frame(width: 50)
                            Text("天")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("", value: $periodRemainingHours, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                                .frame(width: 40)
                            Text("时")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("保存校准") {
                                saveSubscriptionPeriod()
                            }
                            .buttonStyle(.bordered)
                        }
                        if let err = subscriptionPeriodError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.leading, 40)
                        }
                        if subscriptionPeriodStart > 0 {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title2)
                                    .foregroundStyle(.purple)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("周期起点 \(formattedPeriodStart)")
                                        .font(.caption.monospaced())
                                    Text("周期剩余 \(formattedRemaining)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "dollarsign.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("月度额度")
                                    .font(.subheadline.weight(.medium))
                                Text("每月总预算额度")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                Text("$")
                                    .foregroundStyle(.secondary)
                                TextField("", value: $subscriptionBudget, format: .number.precision(.fractionLength(2)))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption.monospaced())
                                    .frame(width: 80)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
```

- [ ] **Step 4: 副标题文案加「含 DSH 估算」**

`token_check/Views/SettingsView.swift:292`：

```swift
                        Text("统计 opencode-go 提供商在订阅周期内的消耗（含 DSH 估算）")
```

- [ ] **Step 5: 新增保存校准与格式化方法**

在 `SettingsView` 结构体内、`body` 之后（如 `settingsHeader` 辅助方法附近）新增：

```swift

    private func saveSubscriptionPeriod() {
        subscriptionPeriodError = nil
        let durationDays = subscriptionPeriodDurationDays
        guard durationDays >= 1 else {
            subscriptionPeriodError = "周期总长至少 1 天"
            return
        }
        guard periodRemainingDays >= 0, periodRemainingHours >= 0, periodRemainingHours <= 23 else {
            subscriptionPeriodError = "剩余小时需在 0–23 之间"
            return
        }
        let totalHours = durationDays * 24
        let remainingHours = periodRemainingDays * 24 + periodRemainingHours
        guard remainingHours <= totalHours else {
            subscriptionPeriodError = "剩余时长不能超过周期总长"
            return
        }
        let nowDate = Date()
        let start = nowDate.addingTimeInterval(-TimeInterval(totalHours - remainingHours) * 3600)
        let startMs = floor(start.timeIntervalSince1970 / 3600) * 3600 * 1000
        subscriptionPeriodStart = startMs
        now = nowDate
    }

    private var formattedPeriodStart: String {
        guard subscriptionPeriodStart > 0 else { return "—" }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: Date(timeIntervalSince1970: subscriptionPeriodStart / 1000))
    }

    private var formattedRemaining: String {
        guard subscriptionPeriodStart > 0 else { return "—" }
        let endMs = subscriptionPeriodStart + Double(subscriptionPeriodDurationDays) * 86_400_000
        let remainMs = endMs - now.timeIntervalSince1970 * 1000
        guard remainMs > 0 else { return "已到期" }
        let hours = Int(remainMs / 3_600_000)
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }
```

- [ ] **Step 6: 挂 60 秒刷新 timer（Form 闭合后追加 modifier）**

`.onReceive` 必须挂在 `Form { ... }` 闭合之后（`token_check/Views/SettingsView.swift:406` 的 `}` 之后），与现有 `.onAppear` / `.formStyle` 等同一 modifier 链。在 415 行 `.frame(width: 820, height: 700)` 之前插入一行：

```swift
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { newNow in
            now = newNow
        }
```

即该区域最终形如：

```swift
        .onAppear {
            loadPricingRules()
            loadDiskInfo()
        }
        .onChange(of: pricingRules) {
            savePricingRules()
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { newNow in
            now = newNow
        }
        .frame(width: 820, height: 700)
    }
```

- [ ] **Step 7: 编译验证**

Run:
```bash
cd /Users/langqin/macapp/token_check && xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
cd /Users/langqin/macapp/token_check && git add token_check/Views/SettingsView.swift && git commit -m "feat: 设置页订阅改为总长+剩余时长校准，显示周期起点与倒计时"
```

---

### Task 3: Widget 端透传周期结束时间 + 大组件剩余时长显示

**Files:**
- Modify: `token_checkWidget/WidgetData.swift:43-160`（WidgetTodayUsage 加字段）
- Modify: `token_checkWidget/token_checkWidget.swift:97-117`（mergeTodayUsage 透传）、`:876-882`（调用处）、`:1197-1215`（subscriptionProgressView）

**Interfaces:**
- Consumes: `TodayUsage.subscriptionPeriodEnd: Double?`（主 app 写入 widget_data.json 的字段）
- Produces: `WidgetTodayUsage.subscriptionPeriodEnd: Double?`；`subscriptionProgressView(used:budget:remaining:periodEnd:)` 新签名

- [ ] **Step 1: WidgetTodayUsage 加字段（声明、CodingKeys、init、decode、encode）**

`token_checkWidget/WidgetData.swift` 的 `struct WidgetTodayUsage`：

1) 在 `let subscriptionEnabled: Bool` 之后加：

```swift
    let subscriptionPeriodEnd: Double?
```

2) CodingKeys 枚举（当前 64-71 行）`case subscriptionRemaining, subscriptionBudget, subscriptionUsed, subscriptionEnabled` 改为：

```swift
        case subscriptionRemaining, subscriptionBudget, subscriptionUsed, subscriptionPeriodEnd, subscriptionEnabled
```

3) init 参数表（当前 89-92 行）`subscriptionEnabled: Bool = false` 之前加：

```swift
        subscriptionPeriodEnd: Double? = nil,
```

4) init 体内 `self.subscriptionEnabled = subscriptionEnabled` 之前加：

```swift
        self.subscriptionPeriodEnd = subscriptionPeriodEnd
```

5) `init(from decoder:)`（当前 132-135 行）`subscriptionEnabled` 行之前加：

```swift
        subscriptionPeriodEnd = try container.decodeIfPresent(Double.self, forKey: .subscriptionPeriodEnd)
```

6) `encode(to:)`（当前 155-158 行）`subscriptionEnabled` 行之前加：

```swift
        try container.encodeIfPresent(subscriptionPeriodEnd, forKey: .subscriptionPeriodEnd)
```

- [ ] **Step 2: mergeTodayUsage 透传**

`token_checkWidget/token_checkWidget.swift:113-116`，在 `subscriptionRemaining: a.subscriptionRemaining ?? b.subscriptionRemaining,` 之后加的对应字段：

```swift
        subscriptionEnabled: a.subscriptionEnabled || b.subscriptionEnabled,
        subscriptionPeriodEnd: a.subscriptionPeriodEnd ?? b.subscriptionPeriodEnd
```

（注意：`subscriptionEnabled` 已在 116 行存在，此处仅追加 `subscriptionPeriodEnd` 一行，位于 `subscriptionEnabled` 之后。）

- [ ] **Step 3: 调用处传 periodEnd**

`token_checkWidget/token_checkWidget.swift:881`：

```swift
                    subscriptionProgressView(used: used, budget: budget, remaining: remaining, periodEnd: usage.subscriptionPeriodEnd)
```

- [ ] **Step 4: subscriptionProgressView 新签名 + 剩余显示**

将 `token_checkWidget/token_checkWidget.swift:1197-1215` 整个方法替换为：

```swift
    private func subscriptionProgressView(used: Double, budget: Double, remaining: Double, periodEnd: Double?) -> some View {
        let ratio = min(used / budget, 1.0)
        let barColor: Color = ratio < 0.5 ? .green : (ratio < 0.8 ? .orange : .red)
        let pct = Int(ratio * 100)
        return HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 48, height: 8)
                Capsule()
                    .fill(barColor.gradient)
                    .frame(width: max(4, 48 * ratio), height: 8)
            }
            Text("\(pct)%")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(barColor)
            if let periodEnd = periodEnd {
                let remainMs = periodEnd - Date().timeIntervalSince1970 * 1000
                if remainMs > 0 {
                    let hours = Int(remainMs / 3_600_000)
                    Text("剩\(hours / 24)天\(hours % 24)h")
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 4)
    }
```

- [ ] **Step 5: 编译验证（widget target 显式构建）**

Run:
```bash
cd /Users/langqin/macapp/token_check && xcodebuild -project token_check.xcodeproj -scheme token_checkWidget -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
cd /Users/langqin/macapp/token_check && git add token_checkWidget/WidgetData.swift token_checkWidget/token_checkWidget.swift && git commit -m "feat: 大组件订阅进度条显示周期剩余天数，widget 数据透传 subscriptionPeriodEnd"
```

---

### Task 4: 端到端验证与收尾

**Files:**
- 无代码改动（验证性任务）

- [ ] **Step 1: 双 target 全量编译**

Run:
```bash
cd /Users/langqin/macapp/token_check && xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3 && xcodebuild -project token_check.xcodeproj -scheme token_checkWidget -configuration Debug build 2>&1 | tail -3
```
Expected: 两个 `** BUILD SUCCEEDED **`

- [ ] **Step 2: 真实环境手工核对清单（用户在 GUI 操作）**

依次验证：

1. 打开设置页 → 订阅计费 → 开启开关 → 输入周期总长 30、剩余 12 天 3 小时 → 点「保存校准」→ 显示「周期起点 yyyy-MM-dd HH:mm」与「周期剩余 12 天 3 小时」（允许 ±1 小时误差）。
2. 核对「周期剩余」与 opencode 官方控制台显示一致（应接近）。
3. 桌面大组件：进度条旁出现「剩12天3h」（下次 widget 刷新后，最长等一个 widgetRefreshInterval）。
4. 将剩余输入改为 30 天 0 小时 → 保存 → 周期起点应约等于当前整点，进度条 used 应为周期内全部 opencode-go 消耗（大幅增加）。
5. 输入剩余 31 天 → 保存 → 出现红色错误「剩余时长不能超过周期总长」，起点不变。
6. 关闭开关 → 大组件进度条消失（与旧行为一致）。

- [ ] **Step 3: 数值合理性核对（可选手动）**

打开 app 日志（Console 或 `log stream --predicate 'subsystem == "com.luoyun.tokencheck"'`），观察 `订阅: periodStart=... durationDays=... budget=...` 与 `订阅已用: X.XX / Y / Z% (含 DSH 估算)`、`订阅 DSH 估算: X.XX` 三行日志，确认：

- `订阅已用` = opencode.db 真实 cost（改前值）+ `订阅 DSH 估算`。
- DSH 估算为非负且量级合理（相对 opencode.db 的 $53.62 为同量级或更小）。

- [ ] **Step 4: 最终提交确认**

Run:
```bash
cd /Users/langqin/macapp/token_check && git status --short && git log --oneline -4
```
Expected: 工作区干净（仅设计/计划文档与三笔 feature commit）；最近 4 条提交包含 Task 1-3 的 commit。

---

## Self-Review 记录

- **Spec 覆盖**：A1-A5（周期模型）→ Task 1 Step 2/4 + Task 2；B（DSH 估算）→ Task 1 Step 3；C（UI）→ Task 2 Step 3-4 + Task 3；D（错误处理）→ Task 1 Step 2 guard、Task 2 Step 3 校验；验证 → Task 4。全部覆盖。
- **占位符**：全部步骤含具体代码/命令，无 TBD。
- **类型一致性**：`computeSubscriptionData` 返回 4 元组在 Task 1 Step 5 消费；`subscriptionPeriodEnd` 字段在 Task 1（主 app）/Task 3（widget）同名同类型；`subscriptionProgressView` 新签名调用处与定义同步改。