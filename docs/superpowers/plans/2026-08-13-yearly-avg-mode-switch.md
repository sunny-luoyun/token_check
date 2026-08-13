# 年度热力图日均模式切换实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 年度热力图 widget 底部日均支持"年度日均 / 使用日均"两种口径，通过右键菜单切换，默认使用日均。

**Architecture:** 改动全部在 widget target（`token_checkWidget/token_checkWidget.swift`）单文件内。使用日均由 widget 端本地计算（`days` 数组已有全年数据）。模式存入 App Group UserDefaults（键 `yearly_avg_mode`），切换后通过 `WidgetCenter.shared.reloadTimelines` 立即刷新。

**Tech Stack:** SwiftUI / WidgetKit / AppIntents / UserDefaults(app group)

## Global Constraints

- **不得修改任何 widget 的 `kind` 值**（AGENTS.md 警告：改 kind 会触发 chronod 卡死）。本计划不涉及 kind 改动。
- UserDefaults suiteName 固定为 `"group.com.luoyun.tokencheck"`。
- 新键名固定为 `yearly_avg_mode`，取值 `"used"`（默认）/ `"calendar"`。
- widget 的 kind 固定为 `"TokenCheckLargeWidgetV3"`（reload 时使用）。
- 不改动 App target（`token_check/` 目录）任何文件，不改 `widget_data.json` 协议。

---
### Task 1: 日均模式读取与显示逻辑

**Files:**
- Modify: `token_checkWidget/token_checkWidget.swift`（读取函数加在 92 行 `largeWidgetChartRange()` 之后；底部标签改在 `yearlyHeatmapContent` 约 957-982 行处）

**Interfaces:**
- Produces: 全局私有函数 `yearlyAvgMode() -> String`（返回 `"used"` 或 `"calendar"`，默认 `"used"`）；`yearlyHeatmapContent` 底部文本按模式显示"年度日均 X"或"使用日均 X"

- [ ] **Step 1: 添加模式读取函数**

在 `largeWidgetChartRange()` 函数（约 92 行）之后插入：

```swift
private func yearlyAvgMode() -> String {
    guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else { return "used" }
    return defaults.string(forKey: "yearly_avg_mode") ?? "used"
}
```

- [ ] **Step 2: 修改底部标签显示逻辑**

`yearlyHeatmapContent` 函数开头（`let grouped = ...` 之后，约 906 行）插入模式与日均计算：

```swift
let avgMode = yearlyAvgMode()
let avgLabel: String
if avgMode == "calendar" {
    avgLabel = "年度日均 \(formatTokens(data.avgDailyTokens))"
} else {
    let usedDays = data.days.filter { $0.totalTokens > 0 }.count
    let avg = usedDays > 0 ? data.totalTokens / usedDays : 0
    avgLabel = "使用日均 \(formatTokens(avg))"
}
```

将约 979 行的：

```swift
Text("日均 \(formatTokens(data.avgDailyTokens))")
```

替换为：

```swift
Text(avgLabel)
```

- [ ] **Step 3: 构建验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED（无错误）

- [ ] **Step 4: Commit**

```bash
git add token_checkWidget/token_checkWidget.swift
git commit -m "feat: 年度热力图支持使用日均/年度日均显示"
```

### Task 2: 右键菜单切换模式

**Files:**
- Modify: `token_checkWidget/token_checkWidget.swift`（`LargeWidgetEntryView.body` 的 `.containerBackground` 之后追加 `.contextMenu`）

**Interfaces:**
- Consumes: Task 1 的 `yearlyAvgMode() -> String`
- Produces: 切换写入函数 `setYearlyAvgMode(_ mode: String)`（写 UserDefaults + reload `TokenCheckLargeWidgetV3`）；`LargeWidgetEntryView` 挂上 contextMenu，两个菜单项带当前模式 checkmark

- [ ] **Step 1: 添加切换写入函数**

在 `yearlyAvgMode()` 函数之后插入：

```swift
private func setYearlyAvgMode(_ mode: String) {
    UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.set(mode, forKey: "yearly_avg_mode")
    WidgetCenter.shared.reloadTimelines(ofKind: "TokenCheckLargeWidgetV3")
}
```

- [ ] **Step 2: 给 LargeWidgetEntryView 挂上 contextMenu**

`LargeWidgetEntryView.body` 中 `.containerBackground(.regularMaterial, for: .widget)` 之后（约 731 行）追加：

```swift
.contextMenu {
    Button {
        setYearlyAvgMode("calendar")
    } label: {
        HStack {
            Text("年度日均")
            if yearlyAvgMode() == "calendar" {
                Image(systemName: "checkmark")
            }
        }
    }
    Button {
        setYearlyAvgMode("used")
    } label: {
        HStack {
            Text("使用日均")
            if yearlyAvgMode() == "used" {
                Image(systemName: "checkmark")
            }
        }
    }
}
```

- [ ] **Step 3: 构建验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED（无错误）

- [ ] **Step 4: 手工验证（macOS 桌面 widget）**

1. 安装/更新 app 与 widget 后，右键年度热力图 widget
2. 确认菜单出现"年度日均 / 使用日均"两项，当前模式（默认使用日均）带 checkmark
3. 点击"年度日均"，widget 立即刷新，底部显示"年度日均 X"且数值 = 总量 ÷ 365/366
4. 再切回"使用日均"，数值 = 总量 ÷ 有使用天数
5. 重启后模式保持

- [ ] **Step 5: Commit**

```bash
git add token_checkWidget/token_checkWidget.swift
git commit -m "feat: 年度热力图右键菜单切换日均口径"
```
