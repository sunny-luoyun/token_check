# 年度热力图日均改为"只算使用的日子" 设计文档

日期：2026-08-13

## 背景

当前年度热力图的"日均"为 `全年总 token ÷ 全年天数（365/366）`，未使用的日期也会拉低日均值，数字不直观。用户希望改为只统计有使用的日子。

## 改动方案

### 1. 计算口径（token_check/Services/WidgetDataService.swift）

`fetchYearlyData()` 中 avg 的计算（原为 `totalTokens / totalDays`）改为：

```swift
let usedDays = days.filter { $0.totalTokens > 0 }.count
let avg = usedDays > 0 ? totalTokens / usedDays : 0
```

- "使用的日子"定义为 `days` 数组中 `totalTokens > 0` 的天数
- `totalTokens` 仍是全年总量，不变
- `YearlyHeatmapData` 结构体字段不变（不新增字段），widget 端无需改动，数据自动透传

### 2. 标签文案（token_checkWidget/token_checkWidget.swift）

年度热力图底部标签由"日均"改为"使用日均"（约 979 行处）。

## 不改动的部分

- 月度热力图的日均口径（仍为 `当月总 token ÷ 当月天数`）
- 年度热力图的其他统计（totalTokens、days、firstWeekday、totalDays）
- widget 数据协议结构

## 验证

- 构建 app 与 widget target，确认编译通过
- 手工确认 widget 年度视图显示的数值 = 全年总量 ÷ 有使用天数
