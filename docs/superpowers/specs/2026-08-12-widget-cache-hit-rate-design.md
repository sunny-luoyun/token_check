# Widget 新增「缓存命中率」指标设计

日期：2026-08-12
状态：已批准（用户确认）

## 目标

在桌面小组件（中组件 `TokenCheckWidgetV2`、大组件 `TokenCheckLargeWidgetV3`）的可选指标列表中加入「缓存命中率」，按今日数据计算，与现有指标口径一致。

## 计算口径

```
缓存命中率 = cacheReadTokens / (cacheReadTokens + inputTokens) × 100%
```

- 与 DeepSeek API `usage.prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` 口径一致（本项目 `tokensCacheRead` 即命中、`tokensInput` 即未命中）
- 分母只含输入侧 token，不含 output / reasoning
- 显示格式：`xx.x%`（一位小数）
- 分母为 0（今日无输入数据）时显示 `—`

## 改动文件

### 1. token_checkWidget/token_checkWidget.swift

- 新增私有函数：

```swift
private func cacheHitRate(for usage: WidgetTodayUsage) -> String {
    let total = usage.cacheReadTokens + usage.inputTokens
    guard total > 0 else { return "—" }
    return String(format: "%.1f%%", Double(usage.cacheReadTokens) / Double(total) * 100)
}
```

- `statValue` switch 加 `case "cacheHitRate": return cacheHitRate(for: usage)`
- `statLabel` switch 加 `case "cacheHitRate": return "缓存命中率"`
- `statColor` switch 加 `case "cacheHitRate": return .teal`

中组件与大组件共用 `statValue`/`statLabel`/`statColor`，一处改动两端生效。

### 2. token_checkWidget/WidgetIntents.swift

- `WidgetStatOption` 枚举加 `case cacheHitRate`
- `caseDisplayRepresentations` 加 `.cacheHitRate: "缓存命中率"`（大组件右键「编辑小组件」可选）

### 3. token_check/Views/SettingsView.swift

- `WidgetStatPicker.allStats` 加 `("cacheHitRate", "缓存命中率")`
- `LargeWidgetStatPicker.allStats` 加 `("cacheHitRate", "缓存命中率")`

## 边界处理

| 场景 | 显示 |
|------|------|
| 今日 cacheRead + input = 0 | `—` |
| 今日有 input、无 cacheRead | `0.0%` |
| 全部命中（无 input） | `100.0%` |

## 明确不做

- 不改 widget `kind`（按 AGENTS.md，避免 chronod 卡顿）
- 不改数据链路 / JSON 结构 / 数据库（`WidgetTodayUsage.inputTokens`/`cacheReadTokens` 已存在）
- 不改默认指标（默认仍为 input/cacheRead/output/session）
- 菜单栏指标（`MenuBarStatPicker`）不加此项（状态栏空间小）

## 验证

1. `xcodebuild` 编译 app + widget 两个 target 通过
2. 运行 app：设置页中/大组件 Picker 出现「缓存命中率」
3. widget 预览选中命中率后显示 `xx.x%`；无数据时显示 `—`
