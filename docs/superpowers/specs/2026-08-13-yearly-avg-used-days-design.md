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

### 3. 切换方式：Edit Widget 配置参数（原方案 contextMenu 废弃）

> 变更记录：最初方案用 `.contextMenu` 右键菜单切换。实测 macOS 26 上 WidgetKit widget 的 `.contextMenu` 不渲染自定义项（右键只显示系统项 Edit/Remove Widget），故废弃该方案，改用 macOS 官方支持的 AppIntentConfiguration 配置参数机制。

- `WidgetIntents.swift` 新增 `YearlyAvgMode` AppEnum（`.used` 使用日均 / `.calendar` 年度日均，显示名"日均口径"）
- `LargeWidgetConfigIntent` 新增参数 `@Parameter(title: "日均口径", default: YearlyAvgMode.used) var avgMode: YearlyAvgMode`
- 系统自动在"右键 → Edit 年度热力图"配置界面生成下拉选择器，选择由系统持久化（每 widget 实例独立），配置变更自动刷新 timeline
- `LargeWidgetEntryView` 新增 `avgMode` 计算属性：优先 `entry.configuration.avgMode`，回退 UserDefaults（`yearly_avg_mode`，兼容旧数据）
- 移除 `.contextMenu` 与 `setYearlyAvgMode`（不再需要）

菜单仅对该 widget（年度热力图）生效，不影响其他 widget（TokenCheck、ClashTraffic）。

## 不改动的部分

- App 端 `WidgetDataService.swift`（`YearlyHeatmapData` 结构、`fetchYearlyData()` 计算）
- widget 数据文件协议（`widget_data.json` 结构不变）
- 月度热力图日均口径
- 其他 widget（TokenCheck 中小组件、ClashTraffic）

## 验证

- 构建 widget target，确认编译通过
- 右键 widget → Edit 年度热力图 → 出现"日均口径"下拉选项（使用日均/年度日均），默认"使用日均"
- 切换后 widget 自动刷新，底部标签与数值随之变化
- 验证数值正确性：使用日均 = 全年总量 ÷ 有使用天数（用已知数据核对）
- 重启后选择保持（系统持久化 intent 参数）
