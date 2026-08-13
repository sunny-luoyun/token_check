# 分时窗口独立价格实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将分时窗口从"倍率"模式改造为"独立价格"模式，支持一个日期段下多个时间区间分别定价。

**Architecture:** 改造 `TimeWindow` 结构（4 个价格字段替换 `priceMultiplier`），旧数据在解码时按"日期段基础价 × 倍率"自动迁移；查价逻辑命中窗口直接返回窗口价；UI 窗口编辑器改为两行布局（时间段 + 4 个价格输入）。

**Tech Stack:** Swift / SwiftUI / Codable

## Global Constraints

- 时间区间整段式（startHour < endHour），不支持跨午夜
- 窗口未覆盖时段用日期段基础价
- 旧数据无缝迁移：`价格 = 日期段基础价 × priceMultiplier`
- 不新增任何依赖
- 项目无测试 target，验证方式：临时脚本 + `xcodebuild` 编译
- 代码注释使用中文

---

### Task 1: 数据模型改造（TimeWindow 独立价格 + 旧数据迁移）

**Files:**
- Modify: `token_check/Models/ModelPricingRule.swift:15-21`（TimeWindow 结构）
- Modify: `token_check/Models/ModelPricingRule.swift:83-108`（ModelPricingRule 解码迁移）
- Modify: `token_check/Models/ModelPricingRule.swift:125-148`（price(at:)）
- Modify: `token_check/Models/ModelPricingRule.swift:47-55`（usesDefaultPricing）
- Test: 临时脚本 `/var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/twip_verify/main.swift`（不入库）

**Interfaces:**
- Produces:
  - `TimeWindow` 新成员构造器：`init(label:startHour:endHour:inputMissPricePerMillion:cacheHitPricePerMillion:outputPricePerMillion:reasoningPricePerMillion:)`
  - `TimeWindow.fileprivate var pendingMultiplier: Double?`（仅解码期临时态，encode 不输出）
  - `ModelPricingRule.price(at:)` 行为变更：命中窗口返回窗口独立价（Task 2 依赖此语义）
- Consumes: 无

- [ ] **Step 1: 替换 TimeWindow 结构**

将 `token_check/Models/ModelPricingRule.swift:15-21` 的旧结构替换为：

```swift
struct TimeWindow: Codable, Identifiable, Hashable {
    var id: String { "\(startHour)-\(endHour)" }
    var label: String
    var startHour: Int
    var endHour: Int
    var inputMissPricePerMillion: Double
    var cacheHitPricePerMillion: Double
    var outputPricePerMillion: Double
    var reasoningPricePerMillion: Double

    fileprivate var pendingMultiplier: Double?

    init(
        label: String,
        startHour: Int,
        endHour: Int,
        inputMissPricePerMillion: Double,
        cacheHitPricePerMillion: Double,
        outputPricePerMillion: Double,
        reasoningPricePerMillion: Double
    ) {
        self.label = label
        self.startHour = startHour
        self.endHour = endHour
        self.inputMissPricePerMillion = inputMissPricePerMillion
        self.cacheHitPricePerMillion = cacheHitPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.reasoningPricePerMillion = reasoningPricePerMillion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        startHour = try container.decode(Int.self, forKey: .startHour)
        endHour = try container.decode(Int.self, forKey: .endHour)
        inputMissPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .inputMissPricePerMillion) ?? 0
        cacheHitPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .cacheHitPricePerMillion) ?? 0
        outputPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .outputPricePerMillion) ?? 0
        reasoningPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .reasoningPricePerMillion) ?? 0
        pendingMultiplier = try container.decodeIfPresent(Double.self, forKey: .priceMultiplier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(startHour, forKey: .startHour)
        try container.encode(endHour, forKey: .endHour)
        try container.encode(inputMissPricePerMillion, forKey: .inputMissPricePerMillion)
        try container.encode(cacheHitPricePerMillion, forKey: .cacheHitPricePerMillion)
        try container.encode(outputPricePerMillion, forKey: .outputPricePerMillion)
        try container.encode(reasoningPricePerMillion, forKey: .reasoningPricePerMillion)
    }

    enum CodingKeys: String, CodingKey {
        case label, startHour, endHour
        case inputMissPricePerMillion, cacheHitPricePerMillion, outputPricePerMillion, reasoningPricePerMillion
        case priceMultiplier
    }
}
```

说明：`pendingMultiplier` 用 `fileprivate` 以便同文件的 `ModelPricingRule` 迁移逻辑访问；`CodingKeys` 含 `priceMultiplier` 仅为解码旧数据，encode 不输出该字段。

- [ ] **Step 2: 在 ModelPricingRule 解码后调用迁移**

将 `token_check/Models/ModelPricingRule.swift:90-91` 改为：

```swift
        if let periods = try container.decodeIfPresent([PricingPeriod].self, forKey: .periods), !periods.isEmpty {
            self.periods = Self.migrateTimeWindows(in: periods)
        } else {
```

并在 `init(from:)` 的闭括号 `}` 之后（`encode(to:)` 之前）插入迁移函数：

```swift
    private static func migrateTimeWindows(in periods: [PricingPeriod]) -> [PricingPeriod] {
        periods.map { period in
            var period = period
            period.timeWindows = period.timeWindows?.map { window in
                var window = window
                if let m = window.pendingMultiplier {
                    window.inputMissPricePerMillion = period.inputMissPricePerMillion * m
                    window.cacheHitPricePerMillion = period.cacheHitPricePerMillion * m
                    window.outputPricePerMillion = period.outputPricePerMillion * m
                    window.reasoningPricePerMillion = period.reasoningPricePerMillion * m
                }
                return window
            }
            return period
        }
    }
```

- [ ] **Step 3: 修改 price(at:) 命中窗口直接返回窗口价**

将 `token_check/Models/ModelPricingRule.swift:134-143` 替换为：

```swift
        let hour = Calendar.current.component(.hour, from: date)
        if let windows = period.timeWindows,
           let window = windows.first(where: { hour >= $0.startHour && hour < $0.endHour }) {
            return (
                window.inputMissPricePerMillion,
                window.cacheHitPricePerMillion,
                window.outputPricePerMillion,
                window.reasoningPricePerMillion
            )
        }
```

- [ ] **Step 4: 修改 usesDefaultPricing 检查窗口价格**

将 `token_check/Models/ModelPricingRule.swift:47-55` 的 `usesDefaultPricing` 替换为：

```swift
    var usesDefaultPricing: Bool {
        periods.allSatisfy { period in
            period.inputMissPricePerMillion == Self.defaultInputMissPricePerMillion
                && period.cacheHitPricePerMillion == Self.defaultCacheHitPricePerMillion
                && period.outputPricePerMillion == Self.defaultOutputPricePerMillion
                && period.reasoningPricePerMillion == Self.defaultReasoningPricePerMillion
                && (period.timeWindows == nil || period.timeWindows!.isEmpty
                    || period.timeWindows!.allSatisfy { window in
                        window.inputMissPricePerMillion == Self.defaultInputMissPricePerMillion
                            && window.cacheHitPricePerMillion == Self.defaultCacheHitPricePerMillion
                            && window.outputPricePerMillion == Self.defaultOutputPricePerMillion
                            && window.reasoningPricePerMillion == Self.defaultReasoningPricePerMillion
                    })
        }
    }
```

- [ ] **Step 5: 写临时验证脚本**

创建 `/var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/twip_verify/main.swift`：

```swift
import Foundation

// 复制项目源码中的 ModelPricingRule 数据模型（裁剪掉 ModelPricingStore，因为它依赖 SharedStorage）

func assertEqual(_ a: Double, _ b: Double, _ label: String) {
    if abs(a - b) < 1e-9 {
        print("PASS: \(label) (\(a))")
    } else {
        print("FAIL: \(label) expected \(b) got \(a)")
        exit(1)
    }
}

// 1. 旧格式（含 priceMultiplier）解码迁移验证
let legacyJSON = """
{
  "providerID": "opencode",
  "modelId": "deepseek-chat",
  "variant": "default",
  "isEnabled": true,
  "periods": [
    {
      "id": "p1",
      "label": "默认",
      "effectiveFrom": -62135596800,
      "effectiveTo": null,
      "inputMissPricePerMillion": 0.14,
      "cacheHitPricePerMillion": 0.0028,
      "outputPricePerMillion": 0.28,
      "reasoningPricePerMillion": 0.28,
      "timeWindows": [
        { "label": "波峰", "startHour": 8, "endHour": 22, "priceMultiplier": 2.0 },
        { "label": "波谷", "startHour": 0, "endHour": 8, "priceMultiplier": 0.5 }
      ]
    }
  ]
}
""".data(using: .utf8)!

let legacyRule = try JSONDecoder().decode(ModelPricingRule.self, from: legacyJSON)
let peak = legacyRule.periods[0].timeWindows![0]
let trough = legacyRule.periods[0].timeWindows![1]
assertEqual(peak.inputMissPricePerMillion, 0.28, "旧格式波峰 输入 0.14x2")
assertEqual(peak.outputPricePerMillion, 0.56, "旧格式波峰 输出 0.28x2")
assertEqual(trough.outputPricePerMillion, 0.14, "旧格式波谷 输出 0.28x0.5")

// 2. 迁移后再编码，不应包含 priceMultiplier 字段
let reencoded = try JSONEncoder().encode(legacyRule)
let encodedString = String(data: reencoded, encoding: .utf8)!
if encodedString.contains("priceMultiplier") {
    print("FAIL: 编码结果仍包含 priceMultiplier")
    exit(1)
} else {
    print("PASS: 编码结果无 priceMultiplier")
}

// 3. price(at:) 窗口内返回窗口价、窗口外返回基础价
let cal = Calendar.current
var comps = DateComponents()
comps.hour = 10
let at10 = cal.date(from: comps)!  // 波峰窗口内
let priceAt10 = legacyRule.price(at: at10)
assertEqual(priceAt10.output, 0.56, "10点(波峰内) 输出价")

comps.hour = 23
let at23 = cal.date(from: comps)!  // 窗口外 → 基础价
let priceAt23 = legacyRule.price(at: at23)
assertEqual(priceAt23.output, 0.28, "23点(窗口外) 输出价 = 基础价")

// 4. 新格式（无 multiplier）直接解码，不迁移
let newJSON = """
{
  "providerID": "opencode",
  "modelId": "deepseek-chat",
  "variant": "default",
  "periods": [
    {
      "id": "p2",
      "label": "默认",
      "effectiveFrom": -62135596800,
      "effectiveTo": null,
      "inputMissPricePerMillion": 0.14,
      "cacheHitPricePerMillion": 0.0028,
      "outputPricePerMillion": 0.28,
      "reasoningPricePerMillion": 0.28,
      "timeWindows": [
        { "label": "夜间特惠", "startHour": 0, "endHour": 8,
          "inputMissPricePerMillion": 0.07, "cacheHitPricePerMillion": 0.0014,
          "outputPricePerMillion": 0.14, "reasoningPricePerMillion": 0.14 }
      ]
    }
  ]
}
""".data(using: .utf8)!
let newRule = try JSONDecoder().decode(ModelPricingRule.self, from: newJSON)
comps.hour = 3
let at3 = cal.date(from: comps)!
let priceAt3 = newRule.price(at: at3)
assertEqual(priceAt3.output, 0.14, "新格式 3点 输出价(窗口独立价)")
assertEqual(newRule.usesDefaultPricing, false, "新格式含窗口 → 非默认")

print("ALL PASS")
```

- [ ] **Step 6: 运行验证脚本**

Run:

```bash
mkdir -p /var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/twip_verify && \
awk '/^enum ModelPricingStore/{exit} {print}' token_check/Models/ModelPricingRule.swift > /var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/twip_verify/model.swift && \
cd /var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/twip_verify && \
swiftc model.swift main.swift -o verify && ./verify
```

说明：`sed` 从源码截取数据模型部分（从文件开头到 `enum ModelPricingStore` 前一行，即剔除依赖 SharedStorage 的存储枚举），与测试 main.swift 一起编译。

Expected: 输出 `ALL PASS`，无 FAIL。

- [ ] **Step 7: xcodebuild 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: 提交**

```bash
git add token_check/Models/ModelPricingRule.swift
git commit -m "feat: 分时窗口改为独立价格，旧倍率数据自动迁移"
```

---

### Task 2: UI 改造（窗口编辑器独立价格 + 布局调整）

**Files:**
- Modify: `token_check/Views/SettingsView.swift:416`（删除 newWindowMultiplier state）
- Modify: `token_check/Views/SettingsView.swift:460`（PricingPeriodEditor 调用处移除参数）
- Modify: `token_check/Views/SettingsView.swift:504-509`（currentPriceSummary 标签展示）
- Modify: `token_check/Views/SettingsView.swift:521-526`（PricingPeriodEditor 属性移除 newWindowMultiplier）
- Modify: `token_check/Views/SettingsView.swift:587-637`（窗口编辑器两行布局）
- Modify: `token_check/Views/SettingsView.swift:639-654`（"添加分时窗口"按钮重置逻辑）
- Modify: `token_check/Views/SettingsView.swift:696-732`（addWindowForm 移除倍率、继承基础价）

**Interfaces:**
- Consumes: Task 1 的 `TimeWindow` 新构造器（label/startHour/endHour/四价）
- Produces: 无（UI 终端）

- [ ] **Step 1: 删除 newWindowMultiplier 状态与传递链**

删除 `SettingsView.swift:416` 的 `@State private var newWindowMultiplier = 0.5`。

将 460 行 PricingPeriodEditor 调用改为：

```swift
                            PricingPeriodEditor(period: $period, addWindowPeriodId: $addWindowPeriodId, newWindowLabel: $newWindowLabel, newWindowStart: $newWindowStart, newWindowEnd: $newWindowEnd, onDelete: {
```

将 525 行 `@Binding var newWindowMultiplier: Double` 删除。

- [ ] **Step 2: 窗口编辑器改为两行布局**

将 587-637 行（`if let windows = period.timeWindows, !windows.isEmpty { ... }` 整块）替换为：

```swift
                if let windows = period.timeWindows, !windows.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { idx, _ in
                            VStack(spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("标签", text: Binding(
                                        get: { period.timeWindows?[idx].label ?? "" },
                                        set: { period.timeWindows?[idx].label = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .frame(width: 70)

                                    hourStepper(value: Binding(
                                        get: { period.timeWindows?[idx].startHour ?? 0 },
                                        set: { period.timeWindows?[idx].startHour = $0 }
                                    ), label: "开始")

                                    Text("→")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    hourStepper(value: Binding(
                                        get: { period.timeWindows?[idx].endHour ?? 24 },
                                        set: { period.timeWindows?[idx].endHour = $0 }
                                    ), label: "结束")

                                    Spacer()

                                    Button {
                                        period.timeWindows?.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                HStack(spacing: 6) {
                                    priceField(label: "无缓存输入", value: Binding(
                                        get: { period.timeWindows?[idx].inputMissPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].inputMissPricePerMillion = $0 }
                                    ))
                                    priceField(label: "缓存命中", value: Binding(
                                        get: { period.timeWindows?[idx].cacheHitPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].cacheHitPricePerMillion = $0 }
                                    ))
                                    priceField(label: "输出", value: Binding(
                                        get: { period.timeWindows?[idx].outputPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].outputPricePerMillion = $0 }
                                    ))
                                    priceField(label: "推理", value: Binding(
                                        get: { period.timeWindows?[idx].reasoningPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].reasoningPricePerMillion = $0 }
                                    ))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 2)
                }
```

- [ ] **Step 3: 修改"添加分时窗口"按钮重置逻辑**

将 642-653 行按钮内的重置代码删除 `newWindowMultiplier = 0.5` 一行，保留其余三行：

```swift
                    Button {
                        addWindowPeriodId = period.id
                        newWindowLabel = ""
                        newWindowStart = 0
                        newWindowEnd = 8
                    } label: {
                        Label("添加分时窗口", systemImage: "plus")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
```

- [ ] **Step 4: 修改 addWindowForm**

将 696-732 行整个 `addWindowForm` 函数替换为（签名不变，`period` 为 PricingPeriodEditor 的 `@Binding`，可直接读基础价作为新窗口默认价）：

```swift
        private func addWindowForm(periodId: String) -> some View {
            HStack(spacing: 4) {
                TextField("标签", text: $newWindowLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 70)
                hourStepper(value: $newWindowStart, label: "开始")
                Text("→")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                hourStepper(value: $newWindowEnd, label: "结束")
                Button("添加") {
                    let label = newWindowLabel.trimmingCharacters(in: .whitespaces)
                    period.timeWindows = period.timeWindows ?? []
                    period.timeWindows?.append(TimeWindow(
                        label: label.isEmpty ? "窗口" : label,
                        startHour: newWindowStart,
                        endHour: newWindowEnd,
                        inputMissPricePerMillion: period.inputMissPricePerMillion,
                        cacheHitPricePerMillion: period.cacheHitPricePerMillion,
                        outputPricePerMillion: period.outputPricePerMillion,
                        reasoningPricePerMillion: period.reasoningPricePerMillion
                    ))
                    addWindowPeriodId = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
                Button("取消") {
                    addWindowPeriodId = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
```

调用处（639-640 行）保持不变：`addWindowForm(periodId: period.id)`。注意 `period` 是 `@Binding`，写入 `period.timeWindows?.append(...)` 会自动写回原数组。

- [ ] **Step 5: 修改 currentPriceSummary 标签展示**

将 504-509 行替换为：

```swift
            if let active = active, let windows = active.timeWindows, !windows.isEmpty {
                let hour = Calendar.current.component(.hour, from: now)
                if let w = windows.first(where: { hour >= $0.startHour && hour < $0.endHour }) {
                    summary += " · \(w.label)"
                }
            }
```

- [ ] **Step 6: xcodebuild 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -Configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 手工验证**

Run: `open /Applications/token_check.app`（若已装旧版则先 `xcodebuild` 产物路径运行：`open $(find ~/Library/Developer/Xcode/DerivedData -name "token_check.app" -path "*Build/Products/Debug*" | head -1)`）

验证要点：
1. 设置 → 模型价格 → 展开模型 → 展开日期段 → 点"添加分时窗口"→ 填写标签/开始/结束 → 添加成功
2. 新窗口四价默认等于日期段基础价，可编辑
3. 添加第二个窗口，两个窗口共存
4. 删除窗口正常
5. 重启 app，窗口配置持久化正常
6. 展开行摘要（当前时段）显示 `· 窗口标签`
7. 费用页历史数据按窗口价重算（波峰时段单价高于波谷）

- [ ] **Step 8: 提交**

```bash
git add token_check/Views/SettingsView.swift
git commit -m "feat: 分时窗口编辑器支持独立价格输入"
```
