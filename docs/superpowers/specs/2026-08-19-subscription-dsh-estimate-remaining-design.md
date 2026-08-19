# 订阅统计：剩余时长校准 + DSH 估算合并 设计文档

日期：2026-08-19
状态：已批准（用户确认 A4 固化起点+倒计时、C 大组件显示剩余天数）

## 背景

opencode 订阅（providerID = `opencode-go`）的用量统计现状存在两处不足：

1. **周期模型不贴合实际**：设置页让用户设定「每月扣费日」（`subscriptionStartDay`），周期按自然月推算。但官方控制台展示的是「周期剩余时长」，周期并不一定是自然月，用户无法据此核对。
2. **DSH 消耗是盲区**：用户把 DSH(DeepSeek Harness) 默认模型路由到 `opencode-go`（`~/.dsh/settings.yaml` 的 `agent-default-model.provider: opencode-go`），但订阅统计只查 opencode.db 的 session 表（`fetchOpenCodeGoCost`），DSH 侧的 opencode-go 消耗（记录在 `~/.dsh` 的投影缓存 + JSONL 事件，不写 opencode.db）完全不计入。DSH 不记录真实费用，只能按价格规则估算。

## 目标

- 去掉「扣费日」设置，改为输入「周期总长 + 当前剩余时长」推算并固化周期起点，使用户能对照官方控制台校准。
- 把 DSH 侧 `opencode-go` 事件的估算消耗并入订阅已用量（无开关，直接合并），使进度条反映全部 opencode-go 消耗趋势。

不引入新开关、不改 budget 语义、不改变剩余=budget-used 的关系。

## 设计

### A. 订阅周期改为「剩余时长校准」模型

1. 删除设置项 `subscriptionStartDay`（扣费日）与 `WidgetDataService.currentSubscriptionStartDate(startDay:)` 推算逻辑。`subscriptionEnabled` 开关保留（先开开关、再填总长/剩余），旧键 `subscriptionStartDay` 直接不再读取、无需迁移清理。
2. 设置页新增输入：**周期总长（天，≥1）**、**剩余天数**、**剩余小时（0–23）**。保存时：
   - `周期起点 = now − (总长 − 剩余时长)`，向下取整到小时（小时级精度足够）。
   - 将起点时间戳固化到 App Group UserDefaults 键 `subscriptionPeriodStart`。
   - 校验：总长 ≥ 1、剩余时长 ≤ 总长、小时 0–23；非法输入提示且不保存。
3. 查询与进度条一律使用**固化的起点**，刷新时不再重算——避免「同样输入 → 每天起点后移一天 → 统计区间滚动收缩」的漂移。
4. 从固化起点**实时倒计时**，显示「周期剩余 X 天 Xh」，供用户对照官方控制台；若倒计时与控制台漂移（续期/手动重置），重新输入即重新固化校准。
5. 未填写新参数（`subscriptionPeriodStart` 缺失）→ 订阅统计不启用，`computeSubscriptionData` 返回 nil（等同现有「未开启」状态）。旧键 `subscriptionStartDay` 不再读取。

### B. DSH 估算并入订阅已用

`WidgetDataService.computeSubscriptionData()` 改为：

```swift
let used = fetchOpenCodeGoCost(startDateMs: startMs)
         + fetchDshOpencodeGoEstimatedCost(startDateMs: startMs)
```

新增 `fetchDshOpencodeGoEstimatedCost(startDateMs: Int64) -> Double`：

- 调 `DshService.shared.loadDetailedData()`，仅 `.success(ds)` 且 `ds.isFull`（事件级数据）时继续；missing/failure/totalsOnly 一律返回 0（与 `DshWidgetDataService` 的 `isFull` 门槛一致）。
- 遍历 `ds.events`，过滤 `event.providerID == "opencode-go"` 且 `event.time ≥ 起点`。
- 每个事件按事件自身的 modelId 取价（variant 固定 `default`）：`ModelPricingStore.price(forModelId: event.modelId, variant: "default", providerID: event.providerID, at: event.time, rules: ds.pricingRules)`（与 DshService L2 费用分解同款口径）。
- 估算公式与 `DshWidgetDataService.costOf` 完全一致（含 reasoning、不含 cacheWrite——定价规则无 cacheWrite 档）：
  `miss/1_000_000 × inputMiss + cacheRead/1_000_000 × cacheHit + output/1_000_000 × output + reasoning/1_000_000 × reasoning`
- 事件循环内增量归总。

### C. UI 变化

- 设置页：删「扣费日」Picker；新增「周期总长（天）」「当前剩余（天 / 小时）」输入区，显示固化起点与实时倒计时。
- 设置副标题「统计 opencode-go 提供商在订阅周期内的消耗」→ 追加「（含 DSH 估算）」。
- 大组件订阅进度条旁新增「剩 X 天 Xh」小字（方便与官方控制台核对）。

### D. 错误处理

- DSH 侧任何异常（缺数据/解析失败/L1 回退）→ 估算为 0，行为与现状一致。
- opencode.db 打不开但 DSH 可用 → `fetchOpenCodeGoCost` 返回 0，估算仍计入（增强而非回归）。
- 无价格规则 → `ModelPricingStore` 现有 fallback 默认价。

## 验证

- `xcodebuild` 编译通过。
- 真实环境：输入剩余时长 → 核对推算起点 / used 值 / 倒计时；抽查 `起点 + 总长 ≈ now + 剩余`。
- 边界：剩余 > 总长、小时越界、未填写时不启用。

## 非目标

- 不做「预估到期日/是否超支」的告警。
- 不改 budget 输入语义。
- 不反向把 opencode CLI 数据算入 DSH。