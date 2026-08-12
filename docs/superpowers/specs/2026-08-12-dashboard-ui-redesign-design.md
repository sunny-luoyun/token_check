# 仪表盘 UI 重构设计

日期：2026-08-12
状态：已确认
范围：纯 View 层重构（token_check 主窗口 app 页面）

## 目标

将当前"系统默认风"的 app 页面改造成**精致数据仪表盘**风格：
- 参照 Linear / Arc / Raycast 的工具类应用视觉语言
- 结构重构：左侧窄图标侧边栏替代顶部 Tab
- 浅色 / 深色模式都好看（动态颜色 + 材质）
- 不动 ViewModel / 数据层 / 业务逻辑

## 非目标

- widget（`token_checkWidget`）与菜单栏 popover 不在本次范围（不改 widget `kind`，避免 chronod 缓存问题）
- 不做用户可切换主题，仅跟随系统深浅色
- 不引入任何新依赖

## 第 1 节：整体框架

### 导航：左侧窄图标侧边栏

- 宽 44pt，纵向排列 4 个图标导航项（费用 / 会话 / 趋势 / 统计）
- 选中态：圆角渐变胶囊背景 + 图标填充色（选中色），未选中为 `.secondary`
- 悬停：图标微亮 + tooltip（icon + 文字）
- 侧边栏背景使用 `ultraThinMaterial` 材质，与内容区自然分隔
- 保留页面切换过渡动画（`.move(edge:)` + `.opacity`）

### 页头（内容区顶部统一）

- 左侧：大标题（如"费用总览"）+ 副标题显示当前时间范围
- 右侧工具条：时间过滤器（紧凑）、刷新按钮、回滚开关（如有）
- 各页现有散落的 `timeFilterBar` 统一收进页头
- 工具条图标 hover 有反馈

### 间距体系

- 内容区外边距 16pt，卡片间距 12pt
- 页头与内容之间 8-12pt

## 第 2 节：视觉语言

### 色彩体系（指标专属色，全局统一）

| 指标 | 颜色 |
|------|------|
| 总费用 | 红 |
| 输入（未命中） | 橙 |
| 缓存命中 | 绿 |
| 输出 | 蓝 |
| 推理 | 紫 |
| 回滚 | 红 |

- `AppTheme` 补全为完整动态颜色板（适配深浅色），全部组件复用，消除硬编码色散落
- `AppTheme.primary` 改为侧边栏选中色，与指标色区分

### 卡片分层

- **主内容卡**：`Color(nsColor: .controlBackgroundColor)` 填充 + 细描边（`.separator.opacity(0.3)`）+ 极轻阴影，承载表格与图表
- **统计卡（升级版 StatCardView）**：
  - 左对齐布局：左上彩色渐变圆角图标块（36pt 方块，渐变 + 阴影）
  - 标题（caption 灰）、大数字（`.system(.largeTitle, design: .monospaced, weight: .bold)`）
  - 副信息（caption2 三级色）
  - hover：整体轻微上浮（scale 1.02）+ 图标块阴影增强

### 图表容器化

- 所有图表放入带标题栏的卡片：左侧标题 + 右侧图例/工具
- 趋势折线图、模型分解条形图均如此处理

### 排版

- 页头标题 `.largeTitle` 粗体，卡内标题 `.headline`
- 数字统一等宽字体（`.monospacedDigit`），仪表感

### 动效

- 统计卡 hover 微反馈
- 页面切换过渡保持现有 `.easeInOut(0.3)`
- 统计卡数字变化轻动画（保留现有 `.spring` 过渡）

## 第 3 节：各页面设计

### 费用页（CostDashboardView）

- 页头 + 5 张统计卡（总费用、输入、缓存、输出、推理），左对齐式
- 总费用卡做"主卡"强调：渐变边框或阴影增强
- "按 Model 分解"主内容卡：
  - 上半：堆叠条形图（每模型输入/输出/缓存/推理四段着色，与表格同色）
  - 下半：现有表格
- 保留回滚角标、加载骨架屏、错误重试视图

### 趋势页（DailyTrendView）

- 三个 picker 合并为一行工具条：时间范围 segmented + 指标 segmented + 图表模式 segmented（紧凑宽度，一行放下）
- 折线图放入主内容卡，标题栏右侧放"模型过滤"chips
- chips 现代化：圆角 pill + 彩色圆点 + 选中填充色

### 会话页（SessionListView）

- 表格套主内容卡
- 行 hover 高亮
- 搜索框从 `.searchable` 改为页头内自定义搜索框（放大镜图标 + 圆角输入框）

### 统计页（StatsView）

- Agent / 项目 / 效率分段保留在页头下方一行（紧凑 segmented）
- 三套内容统一：统计卡 + 主内容卡表格

## 第 4 节：窗口与范围

### 窗口风格

- `MainPanelController.makeMainWindow()` 的 styleMask 从 `[.titled, .closable, .miniaturizable, .resizable, .utilityWindow]` 调整为 regular 风格（去掉 `.utilityWindow`，保留其余），获得标准标题栏
- `MainPanel` 保持 NSPanel 子类即可，`canBecomeKey/canBecomeMain` 不变
- 其余窗口逻辑（隐藏/恢复/激活策略）不动

### 范围边界

- 纯 View 层改动：ContentView、各 View、Components（AppTheme、StatCardView、ViewModifiers、ChartViews、CostBreakdownTable、TimeFilterView）
- 不动：ViewModel、Services、Models、DatabaseService、widget、菜单栏 popover
- 深浅色自动适配

## 验证

1. `xcodebuild` 编译通过（无警告新增）
2. 手动启动 app：切换四个页面、切换时间过滤、刷新、回滚开关、搜索，均正常
3. 深浅色模式各检查一遍
