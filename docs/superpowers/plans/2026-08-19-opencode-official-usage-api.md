# OpenCode 官方用量 API 接入计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将订阅计费统计从本地估算改为使用 OpenCode 官方 `/zen/go/v1/usage` API 获取准确的月度用量百分比，用户只需输入 API Key 即可自动获取订阅额度信息。

**Architecture:** 新建 `OpenCodeUsageService` 封装官方 API 调用；在 `WidgetDataService.computeSubscriptionData()` 中优先使用官方数据；设置页简化为 API Key 输入 + 订阅档位选择；Widget 显示保持不变（进度条 + 百分比 + 剩余天数）。

**Tech Stack:** Swift, URLSession, JSONDecoder, App Group UserDefaults

## Global Constraints

- macOS 14+ (WidgetKit, App Group)
- App Group: `group.com.luoyun.tokencheck`
- 保持向后兼容：旧的本地计算方式作为 fallback
- API Key 存储在 App Group UserDefaults 中（与 DeepSeek API Key 同级，仅本地存储）

---

## 文件变更映射

| 文件 | 操作 | 说明 |
|------|------|------|
| `token_check/Services/OpenCodeUsageService.swift` | **新建** | 封装官方 API 调用 |
| `token_check/Services/WidgetDataService.swift` | 修改 | `computeSubscriptionData()` 优先使用官方 API |
| `token_check/Views/SettingsView.swift` | 修改 | 订阅设置改为 API Key + 档位选择 |
| `token_check/ViewModels/TokenViewModel.swift` | 修改 | 传递 API Key 到数据服务 |
| `token_checkWidget/token_checkWidget.swift` | 修改 | 显示来源标记（可选） |

---

### Task 1: 创建 OpenCodeUsageService

**Files:**
- Create: `token_check/Services/OpenCodeUsageService.swift`

**Interfaces:**
- Produces: `OpenCodeUsageService.fetchUsage(apiKey:) async -> OpenCodeOfficialUsage?`

- [ ] **Step 1: 创建 OpenCodeUsageService.swift**

```swift
import Foundation
import OSLog

/// OpenCode 官方用量 API 服务
/// API: GET https://opencode.ai/zen/go/v1/usage
/// Headers: Authorization: Bearer <key>, x-api-key: <key>
struct OpenCodeOfficialUsage {
    let monthlyPercent: Int      // 月度已用百分比 (0-100)
    let monthlyResetsAt: Date?   // 月度重置时间
    let monthlyStatus: String    // "ok" / "approaching_limit" / "limit_reached"
    let rollingPercent: Int
    let rollingResetsAt: Date?
    let weeklyPercent: Int
    let weeklyResetsAt: Date?
}

final class OpenCodeUsageService {
    static let shared = OpenCodeUsageService()

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "opencode-usage")
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private init() {}

    /// 从官方 API 获取用量数据
    func fetchUsage(apiKey: String) async -> OpenCodeOfficialUsage? {
        guard !apiKey.isEmpty else { return nil }

        let url = URL(string: "https://opencode.ai/zen/go/v1/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("OpenCode usage API 返回非 200: \(code)")
                return nil
            }

            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            let usage = decoded.usage

            let formatter = ISO8601DateFormatter()

            return OpenCodeOfficialUsage(
                monthlyPercent: usage.monthly.percent,
                monthlyResetsAt: formatter.date(from: usage.monthly.resetsAt),
                monthlyStatus: usage.monthly.status,
                rollingPercent: usage.rolling.percent,
                rollingResetsAt: formatter.date(from: usage.rolling.resetsAt),
                weeklyPercent: usage.weekly.percent,
                weeklyResetsAt: formatter.date(from: usage.weekly.resetsAt)
            )
        } catch {
            logger.error("OpenCode usage API 请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Response Models

    private struct UsageResponse: Codable {
        let usage: UsageData
    }

    private struct UsageData: Codable {
        let rolling: PeriodData
        let weekly: PeriodData
        let monthly: PeriodData
    }

    private struct PeriodData: Codable {
        let status: String
        let percent: Int
        let resetsAt: String
    }
}
```

- [ ] **Step 2: 验证编译**

在 Xcode 中确认 `OpenCodeUsageService.swift` 无编译错误。

- [ ] **Step 3: Commit**

```bash
git add token_check/Services/OpenCodeUsageService.swift
git commit -m "feat: add OpenCodeUsageService for official usage API"
```

---

### Task 2: 修改 SettingsView — 订阅设置改为 API Key + 档位

**Files:**
- Modify: `token_check/Views/SettingsView.swift` (订阅计费 Section)

**Interfaces:**
- Consumes: AppGroup UserDefaults (`opencodeApiKey`, `subscriptionTier`)
- Produces: 供 `WidgetDataService` 读取的 UserDefaults 值

**替换逻辑：**
删除旧的 `subscriptionPeriodDurationDays`、`subscriptionPeriodStart`、`subscriptionBudget`、`periodRemainingDays`、`periodRemainingHours` 输入框，替换为：
1. API Key 输入框（SecureField）
2. 订阅档位选择器（$60 标准 / $200 Pro）
3. 可选的手动模式开关（保留旧方式作为 fallback）

- [ ] **Step 1: 修改 SettingsView 订阅 Section**

在 `SettingsView` 中：

1. 新增 `@AppStorage("opencodeApiKey", store: ...)` 和 `@AppStorage("subscriptionTier", store: ...)` 属性
2. 保留旧的 `subscriptionEnabled`、`subscriptionPeriodStart` 等属性（向后兼容）
3. 替换 Section 内容：

将当前的订阅计费 Section（约 L290-L411）替换为：

```swift
Section {
    HStack(spacing: 12) {
        Image(systemName: "creditcard.fill")
            .font(.title2)
            .foregroundStyle(.purple)
            .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
            Text("开启订阅计费统计")
                .font(.subheadline.weight(.medium))
            Text("通过 OpenCode 官方 API 获取准确用量（推荐）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("", isOn: $subscriptionEnabled)
            .labelsHidden()
    }
    if subscriptionEnabled {
        VStack(alignment: .leading, spacing: 10) {
            // API Key 输入
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenCode API Key")
                        .font(.subheadline.weight(.medium))
                    Text("从 OpenCode 控制台获取（sk-opencode-...）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SecureField("sk-opencode-...", text: $opencodeApiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 280)
            }

            // 订阅档位选择
            HStack(spacing: 12) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("订阅档位")
                        .font(.subheadline.weight(.medium))
                    Text("用于将百分比转换为金额显示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $subscriptionTier) {
                    Text("$60/月（标准）").tag(60.0)
                    Text("$200/月（Pro）").tag(200.0)
                }
                .labelsHidden()
                .frame(width: 160)
            }

            // 官方 API 状态
            if !opencodeApiKey.isEmpty {
                if let usage = officialUsage {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("官方 API 已连接")
                                .font(.subheadline.weight(.medium))
                            Text("月度用量 \(usage.monthlyPercent)% · 重置时间 \(formattedResetDate(usage.monthlyResetsAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else if isLoadingOfficialUsage {
                    HStack(spacing: 12) {
                        ProgressView()
                            .frame(width: 28)
                        Text("正在验证 API Key…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("API Key 验证失败")
                                .font(.subheadline.weight(.medium))
                            Text("请检查 Key 是否正确（格式：sk-opencode-...）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            // 向后兼容：手动模式开关
            DisclosureGroup("高级：手动模式（不使用官方 API）") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.day.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("周期总长")
                                .font(.subheadline.weight(.medium))
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
                    HStack(spacing: 12) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("月度额度")
                                .font(.subheadline.weight(.medium))
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
        }
        .padding(.vertical, 2)
    }
} header: {
    settingsHeader(icon: "chart.pie.fill", title: "订阅计费", color: .purple)
}
```

4. 新增状态变量和验证逻辑：

```swift
@AppStorage("opencodeApiKey", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var opencodeApiKey = ""
@AppStorage("subscriptionTier", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionTier = 60.0
@State private var officialUsage: OpenCodeOfficialUsage?
@State private var isLoadingOfficialUsage = false
```

5. 在 `.onAppear` 中添加 API Key 验证：

```swift
.onAppear {
    loadPricingRules()
    loadDiskInfo()
    validateOpenCodeApiKey()
}
.onChange(of: opencodeApiKey) { _, newValue in
    validateOpenCodeApiKey()
}
```

6. 添加验证方法：

```swift
private func validateOpenCodeApiKey() {
    guard !opencodeApiKey.isEmpty else {
        officialUsage = nil
        return
    }
    isLoadingOfficialUsage = true
    Task {
        let usage = await OpenCodeUsageService.shared.fetchUsage(apiKey: opencodeApiKey)
        await MainActor.run {
            self.officialUsage = usage
            self.isLoadingOfficialUsage = false
        }
    }
}

private func formattedResetDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let df = DateFormatter()
    df.dateFormat = "MM-dd HH:mm"
    return df.string(from: date)
}
```

- [ ] **Step 2: 验证编译**

在 Xcode 中确认 SettingsView.swift 无编译错误。

- [ ] **Step 3: Commit**

```bash
git add token_check/Views/SettingsView.swift
git commit -m "feat: simplify subscription settings with API key input"
```

---

### Task 3: 修改 WidgetDataService — 优先使用官方 API

**Files:**
- Modify: `token_check/Services/WidgetDataService.swift` (`computeSubscriptionData()` 方法)

**Interfaces:**
- Consumes: AppGroup UserDefaults (`opencodeApiKey`, `subscriptionTier`, `subscriptionEnabled`)
- Produces: `(used: Double, budget: Double, remaining: Double, periodEnd: Double)?`

**逻辑：**
1. 如果有 `opencodeApiKey`，调用官方 API 获取 `monthlyPercent`
2. 用 `subscriptionTier * percent / 100` 计算 `used`，`subscriptionTier` 作为 `budget`
3. `remaining = budget - used`
4. `periodEnd = monthlyResetsAt` 的毫秒时间戳
5. 如果 API 失败，fallback 到旧的本地计算

- [ ] **Step 1: 修改 computeSubscriptionData()**

将 `computeSubscriptionData()` 方法替换为：

```swift
func computeSubscriptionData() -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)? {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
          defaults.bool(forKey: "subscriptionEnabled") else { return nil }

    // 优先使用官方 API
    let apiKey = defaults.string(forKey: "opencodeApiKey") ?? ""
    if !apiKey.isEmpty {
        return computeOfficialUsage(defaults: defaults, apiKey: apiKey)
    }

    // Fallback: 旧的本地计算方式
    return computeLocalUsage(defaults: defaults)
}

/// 官方 API 用量（同步调用，后台线程执行）
private func computeOfficialUsage(defaults: UserDefaults, apiKey: String) -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: (used: Double, budget: Double, remaining: Double, periodEnd: Double)?

    Task {
        let usage = await OpenCodeUsageService.shared.fetchUsage(apiKey: apiKey)
        if let usage {
            let tier = defaults.double(forKey: "subscriptionTier")
            let budget = tier > 0 ? tier : 60.0
            let used = budget * Double(usage.monthlyPercent) / 100.0
            let remaining = max(budget - used, 0)
            let periodEnd = usage.monthlyResetsAt.map { $0.timeIntervalSince1970 * 1000 } ?? 0
            result = (used, budget, remaining, periodEnd)
            logger.debug("官方 API 用量: \(usage.monthlyPercent)% = $\(String(format: "%.2f", used)) / $\(String(format: "%.0f", budget))")
        } else {
            logger.warning("官方 API 失败，fallback 到本地计算")
            result = computeLocalUsage(defaults: defaults)
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 15)

    return result
}

/// 旧的本地计算方式（向后兼容）
private func computeLocalUsage(defaults: UserDefaults) -> (used: Double, budget: Double, remaining: Double, periodEnd: Double)? {
    let startMs = defaults.double(forKey: "subscriptionPeriodStart")
    let durationDays = defaults.integer(forKey: "subscriptionPeriodDurationDays")
    let budget = defaults.double(forKey: "subscriptionBudget")
    guard startMs > 0, durationDays >= 1, budget > 0 else { return nil }

    let periodEnd = startMs + Double(durationDays) * 86_400_000

    let used = fetchOpenCodeGoCost(startDateMs: Int64(startMs))
             + fetchDshOpencodeGoEstimatedCost(startDateMs: Int64(startMs))
    logger.debug("本地估算用量: $\(String(format: "%.2f", used)) / $\(String(format: "%.0f", budget))")

    return (used, budget, max(budget - used, 0), periodEnd)
}
```

- [ ] **Step 2: 验证编译**

在 Xcode 中确认 WidgetDataService.swift 无编译错误。

- [ ] **Step 3: Commit**

```bash
git add token_check/Services/WidgetDataService.swift
git commit -m "feat: prioritize official API for subscription usage calculation"
```

---

### Task 4: 修改 TokenViewModel — 传递 API Key 到数据服务

**Files:**
- Modify: `token_check/ViewModels/TokenViewModel.swift`

**Interfaces:**
- Consumes: `WidgetDataService.computeSubscriptionData()`
- Produces: 传递给 `TodayUsage` 的订阅数据

**说明：** `TokenViewModel` 调用 `self.service.computeSubscriptionData()` 的逻辑不需要改变，因为 `computeSubscriptionData()` 内部已经处理了 API Key 的读取。但需要确保 API Key 变化时触发刷新。

- [ ] **Step 1: 添加 API Key 变化监听**

在 `TokenViewModel` 中添加对 `opencodeApiKey` 的监听：

```swift
// 在 init() 中添加
NotificationCenter.default.addObserver(
    forName: UserDefaults.didChangeNotification,
    object: UserDefaults(suiteName: "group.com.luoyun.tokencheck"),
    queue: .main
) { [weak self] _ in
    self?.checkApiKeyChanged()
}
```

添加属性和方法：

```swift
private var lastApiKey: String = ""

private func checkApiKeyChanged() {
    let currentKey = UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.string(forKey: "opencodeApiKey") ?? ""
    if currentKey != lastApiKey {
        lastApiKey = currentKey
        // API Key 变化时触发刷新
        refresh(force: true)
    }
}
```

- [ ] **Step 2: 验证编译**

在 Xcode 中确认 TokenViewModel.swift 无编译错误。

- [ ] **Step 3: Commit**

```bash
git add token_check/ViewModels/TokenViewModel.swift
git commit -m "feat: refresh when OpenCode API key changes"
```

---

### Task 5: Widget 显示来源标记（可选）

**Files:**
- Modify: `token_checkWidget/token_checkWidget.swift`

**说明：** 在订阅进度条旁显示数据来源（"官方" vs "估算"），让用户知道数据精度。

- [ ] **Step 1: 添加来源标记**

在 `subscriptionProgressView` 中，在百分比后面添加来源标记：

```swift
private func subscriptionProgressView(used: Double, budget: Double, remaining: Double, periodEnd: Double?, isOfficial: Bool = false) -> some View {
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
        if isOfficial {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 8))
                .foregroundStyle(.green)
        }
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

- [ ] **Step 2: 更新调用处**

找到调用 `subscriptionProgressView` 的地方，传入 `isOfficial` 参数：

```swift
// 在 L897 附近
if usage.subscriptionEnabled,
   let remaining = usage.subscriptionRemaining,
   let budget = usage.subscriptionBudget,
   let used = usage.subscriptionUsed,
   budget > 0 {
    subscriptionProgressView(used: used, budget: budget, remaining: remaining, periodEnd: usage.subscriptionPeriodEnd, isOfficial: UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.string(forKey: "opencodeApiKey")?.isEmpty == false)
}
```

- [ ] **Step 3: 验证编译**

在 Xcode 中确认 token_checkWidget.swift 无编译错误。

- [ ] **Step 4: Commit**

```bash
git add token_checkWidget/token_checkWidget.swift
git commit -m "feat: show official API indicator in subscription progress"
```

---

### Task 6: 清理旧的本地计算逻辑（可选）

**Files:**
- Modify: `token_check/Services/WidgetDataService.swift`

**说明：** 保留 `fetchOpenCodeGoCost()` 和 `fetchDshOpencodeGoEstimatedCost()` 作为 fallback，但添加注释说明它们是旧逻辑。

- [ ] **Step 1: 添加注释标记**

在旧方法上方添加注释：

```swift
// MARK: - 旧的本地计算方式（仅在无 API Key 时 fallback 使用）

/// opencode 费用分解（含回滚调整；失败抛错）
private func fetchOpenCodeGoCost(startDateMs: Int64) -> Double {
    // ... 保持不变 ...
}
```

- [ ] **Step 2: Commit**

```bash
git add token_check/Services/WidgetDataService.swift
git commit -m "chore: mark legacy subscription calculation methods"
```

---

## 验证清单

1. **编译通过**：Xcode 构建无错误
2. **功能测试**：
   - 设置中输入 API Key → 显示"官方 API 已连接" + 月度百分比
   - 小组件显示订阅进度条，数据与官方一致
   - 不输入 API Key → fallback 到旧的本地计算
   - API Key 错误 → 显示验证失败提示
3. **向后兼容**：
   - 旧用户升级后，手动模式开关可展开使用旧方式
   - 无 API Key 时行为与升级前完全一致
4. **安全**：
   - API Key 仅存储在 App Group UserDefaults 中
   - 不上传到任何服务器（除 OpenCode 官方 API 调用外）
