# 分时窗口独立价格设计

日期：2026-08-13

## 背景

现有模型定价已支持"日期段 + 分时窗口"（提交 16a49c7），但分时窗口只能定义**倍率**（`priceMultiplier`），即"基础价 × 倍率"。用户需要每个时间段直接定义**独立价格**（无缓存输入 / 缓存命中 / 输出 / 推理 四个价格字段），实现真正的波峰波谷定价，且支持多个时间区间。

## 需求

1. 每个分时窗口直接填 4 个价格字段，不使用倍率
2. 支持一个日期段下添加多个时间区间
3. 时间区间整段式（startHour < endHour），不支持跨午夜（22:00-06:00 用 00:00-08:00 表达）
4. 窗口未覆盖的时段回退用日期段基础价
5. 旧数据无缝迁移：已有 `priceMultiplier` 的窗口按"日期段基础价 × 倍率"换算为独立价格

## 方案（用户已确认：方案 A）

改造现有 `TimeWindow` 结构，将 `priceMultiplier` 替换为 4 个价格字段。

### 数据模型变更（ModelPricingRule.swift）

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
}
```

删除 `priceMultiplier` 字段。

### 旧数据迁移

`ModelPricingRule.init(from:)` 解码后处理：对每个 period 的 timeWindows，若窗口缺少价格字段（通过自定义 `TimeWindow.init(from:)` 检测 `priceMultiplier` 存在而价格字段缺失），用该 period 的基础价 × multiplier 计算四个价格填充。

实现方式：

```swift
extension TimeWindow {
    init(from decoder: Decoder) throws {
        // 尝试解码 priceMultiplier，若存在则标记为"待迁移"
        // 价格字段缺失时默认 0 并在迁移阶段换算
    }
}
```

注意：`TimeWindow` 是独立 Codable，解码时拿不到 period 基础价，因此迁移换算必须放在 `ModelPricingRule.init(from:)`（有完整 period 上下文）中完成：先正常解码 periods，再遍历填充缺失价格。

`TimeWindow` 自定义 `init(from:)`：四个价格字段全部 `decodeIfPresent`，若均为 nil 且有 `priceMultiplier`，则视为旧格式，将 multiplier 存入临时属性 `private var pendingMultiplier: Double? = nil`，四个价格先填 0。不能以"四价全为 0"判断旧格式，因为用户可能真的把价格设为 0。`ModelPricingRule.init(from:)` 解码完成后调用迁移函数（此时有完整 period 上下文）：

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

`pendingMultiplier` 仅为解码期临时状态：`encode(to:)` 必须自定义（因 `init(from:)` 已自定义），只编码 label / startHour / endHour / 四个价格，不编码 pendingMultiplier。Hashable 合成包含 `Double?` 属性可哈希，无问题；迁移后为 nil。

### 查价逻辑（price(at:)）

匹配到窗口后直接返回窗口价格：

```swift
if let windows = period.timeWindows,
   let window = windows.first(where: { hour >= $0.startHour && hour < $0.endHour }) {
    return (
        window.inputMissPricePerMillion,
        window.cacheHitPricePerMillion,
        window.outputPricePerMillion,
        window.reasoningPricePerMillion
    )
}
return (period.inputMissPricePerMillion, ...)  // 窗口外 → 日期段基础价（不变）
```

### usesDefaultPricing 判断

改为同时检查窗口价格是否等于默认价：

```swift
var usesDefaultPricing: Bool {
    periods.allSatisfy { period in
        period 基础价全部 == 默认价
        && (period.timeWindows == nil || period.timeWindows!.isEmpty
            || period.timeWindows!.allSatisfy { $0 四个价格全部 == 默认价 })
    }
}
```

### UI 变更（SettingsView.swift）

窗口编辑器（第 587-637 行区域）改为两行布局：

- 第一行：时钟图标 + 标签 + 开始→结束小时步进器 + 删除按钮（现有布局，倍率输入框移除）
- 第二行：4 个价格输入框（无缓存输入 / 缓存命中 / 输出 / 推理），复用 `priceField` 组件，与日期段编辑器同风格

`addWindowForm`（第 696-732 行）：移除倍率输入框。新窗口默认价格 = 该 period 当前基础价（四价分别继承），表单仅保留 标签 + 时间段输入 + 添加按钮；添加后再在窗口编辑器里改价格。

`currentPriceSummary`（第 497-514 行）：当前时段命中的窗口改为展示 `· 标签`（价格已由 price(at:) 返回窗口独立价显示在 summary 中）。

### 影响范围

| 文件 | 变更 |
|------|------|
| `token_check/Models/ModelPricingRule.swift` | TimeWindow 结构、解码迁移、price(at:)、usesDefaultPricing |
| `token_check/Views/SettingsView.swift` | 窗口编辑器 UI、addWindowForm、currentPriceSummary |

查价调用方（DatabaseService / CostViewModel / DailyTrendViewModel / WidgetDataService）均通过 `price(at:)` 取价，无需改动。

## 错误处理

- 无匹配窗口 → 日期段基础价（现有行为）
- 无匹配日期段 → 默认价（现有行为）
- 旧数据 multiplier 缺失（极老格式）→ 按 1.0 处理（四价 = 基础价），不崩溃
- 重叠窗口 → 保持先匹配先得，不加校验（YAGNI）

## 测试（项目无测试 target，采用手工验证 + 临时脚本）

- 临时脚本验证：构造含旧格式（multiplier）窗口的 JSON，解码后打印验证 4 价 = 基础价 × multiplier；再编码回 JSON 确认新格式无 multiplier 字段
- 临时脚本验证：`price(at:)` 在窗口内返回窗口价、窗口外返回基础价
- UI 手工验证：添加/编辑/删除窗口、保存后重开持久化正确
- 回归：无窗口的模型定价行为不变；费用/趋势页历史数据重算正常

## 不做的事（YAGNI）

- 不支持跨午夜区间
- 不加窗口重叠校验
- 不加分钟粒度
- 不动 widget 数据格式
