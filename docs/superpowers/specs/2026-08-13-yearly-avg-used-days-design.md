# 年度热力图日均模式切换（右键菜单）设计文档

日期：2026-08-13

## 背景

当前年度热力图底部显示"日均 X"（`全年总 token ÷ 全年天数 365/366`）。用户希望：

1. 保留原口径，标签命名为"年度日均"
2. 新增"使用日均"（`全年总 token ÷ 有使用的天数`，即 `days` 中 `totalTokens > 0` 的天数）
3. 两种模式可通过 widget 右键菜单切换，默认显示"使用日均"

## 方案

改动全部集中在 widget target（`token_checkWidget/token_checkWidget.swift`），App 端零改动。

原因：widget 端 `WidgetYearlyHeatmapData` 已包含 `days: [WidgetDayTokenData]`（全年 365/366 天全量），使用日均可在 widget 端本地计算，无需修改 App 端 `WidgetDataService` 数据协议，也避免 JSON 新旧版本解码兼容问题。

### 1. 显示模式读取

新增 UserDefaults 键（app group: `group.com.luoyun.tokencheck`）：

- 键名：`yearly_avg_mode`
- 取值：`"used"`（使用日均，默认）/ `"calendar"`（年度日均）

新增读取函数：

```swift
private func yearlyAvgMode() -> String {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else { return "used" }
    return defaults.string(forKey: "yearly_avg_mode") ?? "used"
}
```

### 2. 底部标签与数值显示

`yearlyHeatmapContent` 底部（约 979 行处）改为：

- 模式为 `"calendar"`：`年度日均 X`（X = `data.avgDailyTokens`，原有逻辑不变）
- 模式为 `"used"`：`使用日均 X`（X = `data.totalTokens / usedDays`，`usedDays = data.days.filter { $0.totalTokens > 0 }.count`，`usedDays > 0` 时取商，否则 0）

### 3. 右键菜单

在 `LargeWidgetEntryView` 的 `body`（`.containerBackground` 外侧）挂 `.contextMenu`：

- 菜单项"年度日均"：写 `yearly_avg_mode = "calendar"`，reload
- 菜单项"使用日均"：写 `yearly_avg_mode = "used"`，reload
- 当前模式对应的菜单项标记选中态（`Button` 前加 `Toggle` 样式或 `Image(systemName: "checkmark")`）
- reload 方式：`WidgetCenter.shared.reloadTimelines(ofKind: "TokenCheckLargeWidgetV3")`

菜单仅对该 widget（年度热力图）生效，不影响其他 widget（TokenCheck、ClashTraffic）。

## 不改动的部分

- App 端 `WidgetDataService.swift`（`YearlyHeatmapData` 结构、`fetchYearlyData()` 计算）
- widget 数据文件协议（`widget_data.json` 结构不变）
- 月度热力图日均口径
- 其他 widget（TokenCheck 中小组件、ClashTraffic）

## 验证

- 构建 widget target，确认编译通过
- 右键 widget → 菜单出现"年度日均 / 使用日均"两个选项，当前模式有选中标记
- 切换后 widget 立即刷新，底部标签与数值随之变化
- 验证数值正确性：使用日均 = 全年总量 ÷ 有使用天数（用已知数据核对）
- 重启后模式保持（UserDefaults 持久化）
