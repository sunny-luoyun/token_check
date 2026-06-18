# 添加自由选时间段功能

## 目标
在现有年/月/日三级 Picker 筛选基础上，增加「按时间段」模式，用两个 DatePicker 自由选择起止日期。

## 改动清单

### 1. DatabaseService.swift
在 `fetchDailyUsageByModel`、`fetchModelCostBreakdown`、`fetchSessions` 方法中增加 `startDate: Date?` 和 `endDate: Date?` 参数。
当提供起止日期时，使用 `time_created >= ? AND time_created < ?` 进行毫秒时间戳范围查询。

### 2. TokenDeltaTracker.swift
新增 `rollback(from:to:)` 和 `modelRollbacks(from:to:)` 方法，按日期范围过滤回滚数据。

### 3. TimeFilterView.swift
- 新增 `TimeFilterMode` 枚举（`day` / `range`）
- 新增 `@Binding var filterMode`, `@Binding var startDate`, `@Binding var endDate`
- 新增模式切换分段控件
- `.range` 模式下显示两个 DatePicker（开始/结束日期）

### 4. CostViewModel.swift
- 新增 `@Published var filterMode: TimeFilterMode`
- 新增 `@Published var startDate: Date`（默认当月1日）
- 新增 `@Published var endDate: Date`（默认今天）
- `load()` 中根据 mode 调用不同的 DB 方法

### 5. SessionListViewModel.swift
同上。

### 6. DailyTrendViewModel.swift
- `TimeMode` 新增 `.custom` 枚举
- 新增 `filterMode`, `startDate`, `endDate` 属性
- `load()` 中 `.custom` 模式下使用起止日期查询

### 7. CostDashboardView.swift
传递 `$viewModel.filterMode`, `$viewModel.startDate`, `$viewModel.endDate` 给 TimeFilterView。

### 8. SessionListView.swift
同上。

### 9. DailyTrendView.swift
- 在 `timeMode == .custom` 时，显示 TimeFilterView（自动支持两种子模式切换）

## 数据库查询变化
- 原：`strftime('%Y/ %m/ %d')` 字符串匹配
- 新增：`time_created >= startMillis AND time_created < endMillis` 时间戳范围（利用索引，性能更好）
