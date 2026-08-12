# 仪表盘 UI 重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 token_check app 页面从"系统默认风"重构为精致数据仪表盘风格：左侧窄图标侧边栏 + 统一页头 + 升级统计卡 + 图表容器化 + regular 窗口。

**Architecture:** 纯 View 层重构。先扩展 `AppTheme` 颜色板，再重构全局框架（侧边栏 + 页头组件 + 卡片组件），然后逐个页面接入，最后调整窗口风格。ViewModel/数据层/业务逻辑全部不动。

**Tech Stack:** SwiftUI（macOS 14+）、Swift Charts（已引入）

## Global Constraints

- 不动 ViewModel / Services / Models / DatabaseService / widget / 菜单栏 popover
- 全部颜色必须走动态颜色，深浅色自动适配（`Color(nsColor:)` / `.primary` / `.secondary` / `.separator` / `.quaternary`）
- 不引入任何新依赖
- 项目无测试 target，每个任务以 `xcodebuild` 编译通过 + 手动验证作为验收
- 编译命令：`xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build`，期望输出包含 `BUILD SUCCEEDED`
- 提交信息风格参考仓库：`feat: ...` / `refactor: ...` / `fix: ...`（中文描述）

---

### Task 1: 扩展 AppTheme 颜色板

**Files:**
- Modify: `token_check/Views/Components/AppTheme.swift`（整个文件重写）

**Interfaces:**
- Produces: `AppTheme` 新增属性——指标色 `cost/.red`、`inputMiss/.orange`、`cacheHit/.green`、`output/.blue`、`reasoning/.purple`、`rollback/.red`；卡片表面色 `surfaceCard`（`Color(nsColor: .controlBackgroundColor)`）；侧边栏材质 `sidebarMaterial: Material = .ultraThinMaterial`；侧边栏选中色 `sidebarSelection: Color = .blue`
- 后续所有任务通过 `@Environment(\.appTheme) var theme` 使用这些属性

**说明：** 现有文件里的 `primary/.blue`、`secondary/.teal`、`accent/.indigo` 保留（其他地方可能引用），只做新增。

- [ ] **Step 1: 重写 AppTheme.swift**

```swift
import SwiftUI

struct AppTheme {
    // 导航 / 强调
    let primary: Color = .blue
    let secondary: Color = .teal
    let accent: Color = .indigo

    // 指标专属色（全局统一，深浅色自动适配）
    let cost: Color = .red
    let inputMiss: Color = .orange
    let cacheHit: Color = .green
    let output: Color = .blue
    let reasoning: Color = .purple
    let rollback: Color = .red

    // 表面
    let surfacePrimary: Color = Color(nsColor: .windowBackgroundColor)
    let surfaceSecondary: Color = Color(nsColor: .underPageBackgroundColor)
    let surfaceCard: Color = Color(nsColor: .controlBackgroundColor)
    let sidebarMaterial: Material = .ultraThinMaterial
    let sidebarSelection: Color = .blue

    // 圆角
    let radiusSmall: CGFloat = 8
    let radiusMedium: CGFloat = 12
    let radiusLarge: CGFloat = 16

    // 阴影
    let shadowSmall: CGFloat = 4
    let shadowMedium: CGFloat = 8
    let shadowLarge: CGFloat = 12

    // 间距
    let spacingSmall: CGFloat = 4
    let spacingMedium: CGFloat = 8
    let spacingLarge: CGFloat = 16
    let spacingXLarge: CGFloat = 24
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme()
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add token_check/Views/Components/AppTheme.swift
git commit -m "feat: 扩展 AppTheme 指标专属色与卡片表面色"
```

---

### Task 2: 侧边栏 + 页头组件

**Files:**
- Create: `token_check/Views/Components/SidebarView.swift`
- Create: `token_check/Views/Components/PageHeaderView.swift`
- Modify: `token_check/ContentView.swift`（整体重写为侧边栏布局）

**Interfaces:**
- Consumes: `AppTab` 枚举（ContentView 现有定义，保持不变，含 `icon` 属性）
- Produces: `SidebarView(selectedTab: Binding<AppTab>)`；`PageHeaderView<Content: View>(title: String, subtitle: String?, toolbar: Content)`

**Step 1: 创建 SidebarView.swift**

```swift
import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: AppTab

    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(spacing: 6) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? theme.sidebarSelection : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected
                                    ? LinearGradient(
                                        colors: [theme.sidebarSelection.opacity(0.22), theme.sidebarSelection.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing)
                                    : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? theme.sidebarSelection.opacity(0.3) : .clear, lineWidth: 1)
                        )
                        .contentShape(.interaction, .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(tab.rawValue)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: 44)
        .background(theme.sidebarMaterial)
    }
}
```

**Step 2: 创建 PageHeaderView.swift**

```swift
import SwiftUI

struct PageHeaderView<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var toolbar: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            toolbar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
```

**Step 3: 重写 ContentView.swift**

```swift
import SwiftUI

enum AppTab: String, CaseIterable {
    case cost = "费用"
    case session = "会话"
    case trend = "趋势"
    case stats = "统计"

    var icon: String {
        switch self {
        case .cost: return "yensign.circle.fill"
        case .session: return "list.bullet"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .stats: return "chart.bar.fill"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .cost

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selectedTab: $selectedTab)

            Divider()

            ZStack {
                if selectedTab == .cost {
                    CostDashboardView()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if selectedTab == .session {
                    SessionListView()
                        .transition(.push(from: selectedTab == .cost ? .trailing : .leading))
                }
                if selectedTab == .trend {
                    DailyTrendView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if selectedTab == .stats {
                    StatsView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: selectedTab)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
```

**Step 4: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 5: 提交**

```bash
git add token_check/Views/Components/SidebarView.swift token_check/Views/Components/PageHeaderView.swift token_check/ContentView.swift
git commit -m "refactor: 侧边栏导航 + 统一页头组件"
```

---

### Task 3: 统计卡升级 + 主内容卡样式

**Files:**
- Modify: `token_check/Views/Components/StatCardView.swift`（整体重写）
- Modify: `token_check/Views/Components/ViewModifiers.swift`（新增 MainContentCard）

**Interfaces:**
- Consumes: `AppTheme.surfaceCard`、`AppTheme.radiusMedium`
- Produces: `StatCardView(title:value:subtitle:icon:color:emphasized:)`，新增 `emphasized: Bool = false` 参数（总费用主卡用 `true`）；View 扩展 `.mainContentCard()`（主内容卡容器）

**Step 1: 重写 StatCardView.swift（左对齐 + emphasized 主卡）**

```swift
import SwiftUI

struct StatCardView: View {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let color: Color
    var emphasized: Bool = false

    @Environment(\.appTheme) var theme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(color.gradient)
                    )
                    .shadow(color: color.opacity(0.35), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)

                Spacer()

                if emphasized {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(color.opacity(0.8))
                }
            }

            Text(value)
                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(theme.surfaceCard)
                .shadow(color: color.opacity(isHovering ? 0.18 : 0.08), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .stroke(color.opacity(isHovering ? 0.35 : 0.15), lineWidth: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(color.opacity(0.03))
        )
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
```

**Step 2: ViewModifiers.swift 新增 MainContentCard**

在 `CardStyle` 之后追加：

```swift
struct MainContentCard: ViewModifier {
    @Environment(\.appTheme) var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: theme.radiusMedium)
                    .fill(theme.surfaceCard)
                    .shadow(color: .black.opacity(0.05), radius: theme.shadowSmall, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMedium)
                    .stroke(.separator.opacity(0.3), lineWidth: 1)
            )
    }
}
```

并在 `extension View` 中追加：

```swift
    func mainContentCard() -> some View {
        modifier(MainContentCard())
    }
```

**Step 3: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: 提交**

```bash
git add token_check/Views/Components/StatCardView.swift token_check/Views/Components/ViewModifiers.swift
git commit -m "feat: 统计卡左对齐升级与主内容卡样式"
```

---

### Task 4: 费用页重构（页头 + 主卡强调 + Model 分解卡）

**Files:**
- Modify: `token_check/Views/CostDashboardView.swift`
- Modify: `token_check/Views/Components/ChartViews.swift`（新增 ModelBreakdownStackedChart）

**Interfaces:**
- Consumes: `PageHeaderView`、`StatCardView(emphasized:)`、`.mainContentCard()`、`AppTheme` 指标色
- Produces: `ModelBreakdownStackedChart(modelUsage: [ModelCostBreakdown])`——按模型堆叠条形图，四段：输入（`theme.inputMiss`）/缓存（`theme.cacheHit`）/输出（`theme.output`）/推理（`theme.reasoning`）

**Step 1: ChartViews.swift 新增堆叠条形图**

文件末尾追加：

```swift
struct ModelBreakdownStackedChart: View {
    let modelUsage: [ModelCostBreakdown]

    @Environment(\.appTheme) var theme
    @State private var isAnimated = false

    var body: some View {
        Chart {
            ForEach(modelUsage) { item in
                BarMark(
                    x: .value("Tokens", item.cacheMissTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Input"))
                .opacity(isAnimated ? 1 : 0)

                BarMark(
                    x: .value("Tokens", item.cacheHitTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Cache"))
                .opacity(isAnimated ? 1 : 0)

                BarMark(
                    x: .value("Tokens", item.outputTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Output"))
                .opacity(isAnimated ? 1 : 0)

                BarMark(
                    x: .value("Tokens", item.reasoningTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Reasoning"))
                .opacity(isAnimated ? 1 : 0)
            }
        }
        .chartForegroundStyleScale([
            "Input": theme.inputMiss,
            "Cache": theme.cacheHit,
            "Output": theme.output,
            "Reasoning": theme.reasoning
        ])
        .chartXAxisLabel("Tokens")
        .frame(height: CGFloat(max(modelUsage.count * 40, 120)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).delay(0.1)) {
                isAnimated = true
            }
        }
        .onChange(of: modelUsage.count) { _, _ in
            isAnimated = false
            withAnimation(.easeInOut(duration: 0.6).delay(0.1)) {
                isAnimated = true
            }
        }
    }
}
```

注意：`ModelCostBreakdown` 需满足 `Identifiable`（现有 `CostBreakdownTable` 已用 `Table(breakdown)`，说明已遵循）。

**Step 2: 重写 CostDashboardView body 的 summaryCards 部分**

将 `summaryCards(summary:)` 中 5 张卡的调用改为传 `emphasized`（总费用卡），并保持 `transition`：

```swift
    private func summaryCards(summary: CostSummary) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            StatCardView(
                title: "总费用",
                value: formatCost(summary.totalCost),
                subtitle: "\(summary.sessionCount) 个会话",
                icon: "yensign.circle.fill",
                color: theme.cost,
                emphasized: true
            )
            .transition(.scale.combined(with: .opacity))

            StatCardView(
                title: "输入（未命中）",
                value: formatTokens(summary.totalMissTokens),
                subtitle: formatCost(summary.missCost),
                icon: "arrowtriangle.down.circle.fill",
                color: theme.inputMiss
            )
            .transition(.scale.combined(with: .opacity))

            StatCardView(
                title: "缓存命中",
                value: formatTokens(summary.totalHitTokens),
                subtitle: formatCost(summary.hitCost),
                icon: "memorychip.fill",
                color: theme.cacheHit
            )
            .transition(.scale.combined(with: .opacity))

            StatCardView(
                title: "输出",
                value: formatTokens(summary.totalOutputTokens),
                subtitle: formatCost(summary.outputCost),
                icon: "arrowtriangle.up.circle.fill",
                color: theme.output
            )
            .transition(.scale.combined(with: .opacity))

            StatCardView(
                title: "推理",
                value: formatTokens(summary.totalReasoningTokens),
                subtitle: formatCost(summary.reasoningCost),
                icon: "brain.head.profile.fill",
                color: theme.reasoning
            )
            .transition(.scale.combined(with: .opacity))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: summary.totalCost)
    }
```

**Step 3: 重写 CostDashboardView 的 body 与 costTable**

将整个 `body` 替换为（保留 loadingSkeleton / errorView / timeFilterBar 不动）：

```swift
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loadingSkeleton
            } else if let error = viewModel.error {
                errorView(error)
            } else if let summary = viewModel.summary {
                VStack(spacing: 0) {
                    PageHeaderView(
                        title: "费用总览",
                        subtitle: headerSubtitle
                    ) {
                        HStack(spacing: 8) {
                            TimeFilterView(
                                years: viewModel.availableYears,
                                months: viewModel.availableMonths,
                                days: viewModel.availableDays,
                                selectedYear: $viewModel.selectedYear,
                                selectedMonth: $viewModel.selectedMonth,
                                selectedDay: $viewModel.selectedDay,
                                filterMode: $viewModel.filterMode,
                                startDate: $viewModel.startDate,
                                endDate: $viewModel.endDate,
                                onChange: { viewModel.applyFilter() }
                            )
                            headerToolbarButtons
                        }
                    }

                    Divider()

                    ScrollView {
                        VStack(spacing: 12) {
                            summaryCards(summary: summary)
                                .overlay(alignment: .topTrailing) {
                                    if viewModel.hasRollback {
                                        HStack(spacing: 2) {
                                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                            Text("+\(formatTokens(viewModel.rollbackTotal))")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.red)
                                        }
                                        .offset(x: -4, y: 4)
                                    }
                                }

                            costTable
                        }
                        .padding(16)
                    }

                    costFooter(summary: summary)
                        .padding()
                }
            }
        }
        .navigationTitle("费用")
        .onAppear {
            viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: SharedStorage.pricingRulesUpdated)) { _ in
            viewModel.load()
        }
    }
```

新增两个私有视图，插入到 `timeFilterBar` 之后：

```swift
    private var headerSubtitle: String {
        let v = viewModel
        if v.filterMode == .range {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return "\(df.string(from: v.startDate)) ~ \(df.string(from: v.endDate))"
        }
        if let y = v.selectedYear {
            if let m = v.selectedMonth {
                return "\(y)年 \(Int(m) ?? 0)月"
            }
            return "\(y)年"
        }
        return "全部时间"
    }

    private var headerToolbarButtons: some View {
        HStack(spacing: 6) {
            Button(action: { viewModel.applyFilter() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .padding(6)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
            .help("刷新")

            Toggle(isOn: $viewModel.showRollback) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.caption)
                    .padding(6)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .help("显示回滚消耗")
            .disabled(!viewModel.hasRollback)
            .onChange(of: viewModel.showRollback) { _, _ in
                viewModel.applyFilter()
            }
        }
    }
```

**Step 4: costTable 改为卡片内"图表 + 表格"**

将 `costTable` 替换为：

```swift
    private var costTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按 Model 分解")
                    .font(.headline)
                Spacer()
            }

            if !viewModel.modelBreakdown.isEmpty {
                ModelBreakdownStackedChart(modelUsage: viewModel.modelBreakdown)
                    .frame(height: CGFloat(max(viewModel.modelBreakdown.count * 40, 120)))
            }

            CostBreakdownTable(breakdown: viewModel.modelBreakdown)
                .frame(minHeight: 100, idealHeight: 360)
        }
        .padding(16)
        .mainContentCard()
    }
```

原 `.toolbar { ... }` 中刷新与回滚按钮已移入页头，删除整个 `.toolbar` 闭包（保留 `.navigationTitle`）。

**Step 5: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 6: 提交**

```bash
git add token_check/Views/CostDashboardView.swift token_check/Views/Components/ChartViews.swift
git commit -m "feat: 费用页页头整合 + Model 堆叠图卡片"
```

---

### Task 5: 趋势页重构（picker 单行工具条 + 图表卡片 + chips 现代化）

**Files:**
- Modify: `token_check/Views/DailyTrendView.swift`

**Consumes:** `PageHeaderView`、`.mainContentCard()`、`AppTheme`

**Step 1: 重写 body 为页头 + 卡片化图表**

将 `var body: some View` 的 `else` 分支替换为：

```swift
            } else {
                VStack(spacing: 0) {
                    PageHeaderView(
                        title: "趋势",
                        subtitle: headerSubtitle
                    ) {
                        headerToolbar
                    }

                    Divider()

                    ScrollView {
                        VStack(spacing: 12) {
                            chartCard

                            if viewModel.rolledBackTotal > 0 {
                                HStack {
                                    Image(systemName: "arrow.counterclockwise.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption2)
                                    Text("含回滚 +\(formatTokens(viewModel.rolledBackTotal))")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
```

**Step 2: 新增 headerToolbar（三个 picker 合并为一行）**

将原来的 `timeFilterBar`、`metricFilterBar`、`chartModeBar` 三个属性删除，替换为：

```swift
    private var headerSubtitle: String {
        let v = viewModel
        if v.isMonthlyMode || v.isCustomMode {
            if v.isCustomMode {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                return "\(df.string(from: v.startDate)) ~ \(df.string(from: v.endDate))"
            }
            if let y = v.selectedYear, let m = v.selectedMonth {
                return "\(y)年 \(Int(m) ?? 0)月"
            }
        }
        return "\(v.timeMode.rawValue)"
    }

    private var headerToolbar: some View {
        HStack(spacing: 12) {
            Picker("时间范围", selection: $viewModel.timeMode) {
                ForEach(DailyTrendViewModel.TimeMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

            if viewModel.isMonthlyMode || viewModel.isCustomMode {
                TimeFilterView(
                    years: viewModel.availableYears,
                    months: viewModel.availableMonths,
                    days: viewModel.availableDays,
                    selectedYear: $viewModel.selectedYear,
                    selectedMonth: $viewModel.selectedMonth,
                    selectedDay: $viewModel.selectedDay,
                    filterMode: viewModel.isCustomMode ? .constant(.range) : $viewModel.filterMode,
                    startDate: $viewModel.startDate,
                    endDate: $viewModel.endDate,
                    onChange: { viewModel.applyFilter() }
                )
            }

            Spacer()

            Picker("指标", selection: $viewModel.selectedMetric) {
                ForEach(DailyTrendViewModel.MetricType.allCases, id: \.self) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)

            Picker("模式", selection: $viewModel.chartMode) {
                ForEach(DailyTrendViewModel.ChartMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Button(action: { viewModel.applyFilter() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .padding(6)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
            .help("刷新")
        }
    }
```

**Step 3: 新增 chartCard（图表 + 模型 chips 容器化）**

```swift
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(chartTitle)
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                modelChips
            }

            chartSection
        }
        .padding(16)
        .mainContentCard()
    }

    private var chartTitle: String {
        switch viewModel.chartMode {
        case .token: return "Token 趋势"
        case .cost: return "费用趋势"
        }
    }
```

**Step 4: modelChips 现代化（替换原 modelLegend）**

将 `modelLegend` 替换为：

```swift
    private var modelChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.availableModels, id: \.self) { model in
                    let idx = viewModel.availableModels.firstIndex(of: model) ?? 0
                    let color = modelColors[idx % modelColors.count]
                    let isSelected = viewModel.selectedModels.contains(model)

                    Button {
                        if isSelected {
                            viewModel.selectedModels.remove(model)
                        } else {
                            viewModel.selectedModels.insert(model)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isSelected ? color : color.opacity(0.3))
                                .frame(width: 8, height: 8)
                            Text(model)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(isSelected ? color.opacity(0.15) : Color.gray.opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? color.opacity(0.5) : Color.gray.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: 420)
    }
```

删除原 `.toolbar` 闭包（刷新按钮已移入页头），保留 `.navigationTitle`、`.onAppear`、`.onReceive`。

**Step 5: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 6: 提交**

```bash
git add token_check/Views/DailyTrendView.swift
git commit -m "feat: 趋势页工具条单行化 + 图表卡片化"
```

---

### Task 6: 会话页重构（自定义搜索框 + 表格卡片化 + 行 hover）

**Files:**
- Modify: `token_check/Views/SessionListView.swift`

**Consumes:** `PageHeaderView`、`.mainContentCard()`

**Step 1: body 改为页头 + 主内容卡表格**

替换 `else` 分支与 `.toolbar`/`.searchable` 修饰符，最终文件整体为：

```swift
import SwiftUI

struct SessionListView: View {
    @StateObject private var viewModel = SessionListViewModel()
    @State private var hoveredSessionID: Session.ID?

    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    Spacer()
                    RoundedRectangle(cornerRadius: theme.radiusMedium)
                        .fill(.quaternary.opacity(0.5))
                        .frame(height: 40)
                        .shimmering()
                        .padding(.horizontal)
                    RoundedRectangle(cornerRadius: theme.radiusMedium)
                        .fill(.quaternary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .shimmering()
                        .padding(.horizontal)
                    Spacer()
                }
                .transition(.opacity)
            } else if let error = viewModel.error {
                errorView(error)
            } else {
                VStack(spacing: 0) {
                    PageHeaderView(
                        title: "会话历史",
                        subtitle: "\(viewModel.filteredSessions.count) 个会话"
                    ) {
                        HStack(spacing: 8) {
                            searchField

                            TimeFilterView(
                                years: viewModel.availableYears,
                                months: viewModel.availableMonths,
                                days: viewModel.availableDays,
                                selectedYear: $viewModel.selectedYear,
                                selectedMonth: $viewModel.selectedMonth,
                                selectedDay: $viewModel.selectedDay,
                                filterMode: $viewModel.filterMode,
                                startDate: $viewModel.startDate,
                                endDate: $viewModel.endDate,
                                onChange: { viewModel.applyFilter() }
                            )

                            Button(action: viewModel.applyFilter) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.quaternary.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                            .help("刷新")

                            Toggle(isOn: $viewModel.showRollback) {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.quaternary.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.plain)
                            .help("显示回滚消耗")
                            .disabled(!viewModel.hasSessionRollback)
                            .onChange(of: viewModel.showRollback) { _, _ in
                                viewModel.applyFilter()
                            }
                        }
                    }

                    Divider()

                    sessionTable
                        .padding(16)
                }
            }
        }
        .navigationTitle("会话历史")
        .onAppear {
            viewModel.load()
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.filteredSessions.count)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索标题、模型或项目", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.3))
        )
        .frame(width: 200)
    }

    private var sessionTable: some View {
        Table(viewModel.filteredSessions) {
            TableColumn("时间") { session in
                Text(session.timeCreated, style: .date)
                    .font(.caption)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(100)

            TableColumn("标题") { session in
                Text(session.title ?? session.slug ?? "(无标题)")
                    .lineLimit(1)
                    .foregroundStyle(hoveredSessionID == session.id ? Color.accentColor : .primary)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }

            TableColumn("模型") { session in
                Text(session.modelDisplayName)
                    .font(.caption)
                    .foregroundStyle(hoveredSessionID == session.id ? Color.accentColor : .secondary)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(160)

            TableColumn("Input") { session in
                let rollback = viewModel.showRollback ? viewModel.sessionRollbacks[session.id] : nil
                let adjusted = session.tokensInput + (rollback?.asTokenData.tokensInput ?? 0)
                Text(formatNumber(adjusted))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(90)

            TableColumn("Output") { session in
                let rollback = viewModel.showRollback ? viewModel.sessionRollbacks[session.id] : nil
                let adjusted = session.tokensOutput + (rollback?.asTokenData.tokensOutput ?? 0)
                Text(formatNumber(adjusted))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(90)

            TableColumn("Cost") { session in
                Text(String(format: "$%.4f", session.cost))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(80)
        }
        .alternatingRowBackgrounds()
        .frame(minHeight: 200, maxHeight: .infinity)
        .mainContentCard()
    }
```

注意：SwiftUI Table 的 `tableRowBackground` 无法按行区分（拿不到行 id），因此行 hover 反馈改为：hover 时该行"标题"和"模型"列文本变为 accent 色，其他列不变（数值列保持 monospaced 数字清晰度）。

**Step 2: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 3: 提交**

```bash
git add token_check/Views/SessionListView.swift
git commit -m "feat: 会话页搜索框入页头 + 表格卡片化与行高亮"
```

---

### Task 7: 统计页重构（分段行 + 内容容器化）

**Files:**
- Modify: `token_check/Views/StatsView.swift`

**Consumes:** `PageHeaderView`、`.mainContentCard()`、`AppTheme`

**Step 1: body 改为页头 + 分段行 + 卡片化内容**

替换 `var body: some View` 的 `else` 分支：

```swift
            } else {
                VStack(spacing: 0) {
                    PageHeaderView(
                        title: "统计",
                        subtitle: segmentSubtitle
                    ) {
                        HStack(spacing: 8) {
                            TimeFilterView(
                                years: viewModel.availableYears,
                                months: viewModel.availableMonths,
                                days: viewModel.availableDays,
                                selectedYear: $viewModel.selectedYear,
                                selectedMonth: $viewModel.selectedMonth,
                                selectedDay: $viewModel.selectedDay,
                                filterMode: $viewModel.filterMode,
                                startDate: $viewModel.startDate,
                                endDate: $viewModel.endDate,
                                onChange: { viewModel.applyFilter() }
                            )
                            Button(action: viewModel.applyFilter) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.quaternary.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                            .help("刷新")
                        }
                    }

                    Picker("统计维度", selection: $selectedSegment) {
                        ForEach(StatsSegment.allCases, id: \.self) { seg in
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                    Divider()

                    ScrollView {
                        VStack(spacing: 0) {
                            switch selectedSegment {
                            case .agent: agentContent
                            case .project: projectContent
                            case .efficiency: efficiencyContent
                            }
                        }
                    }
                }
            }
```

删除原 `timeFilterBar`、`segmentPicker` 两个属性。

**Step 2: 新增 segmentSubtitle**

在 `body` 之后新增：

```swift
    private var segmentSubtitle: String {
        switch selectedSegment {
        case .agent: return "按 Agent 维度统计"
        case .project: return "按项目维度统计"
        case .efficiency: return "代码效率统计"
        }
    }
```

**Step 3: 三套内容表格套 mainContentCard**

- `agentTable` / `projectTable` / `efficiencyTable`：在 `.frame(...)` 后追加 `.mainContentCard()` 并外层加 `.padding(16)`——即把各自的调用处改为：

```swift
                agentTable
                    .padding(16)
```

```swift
                projectTable
                    .padding(16)
```

```swift
                efficiencyTable
                    .padding(16)
```

- 每个 Table 的 `.frame(minHeight: 100, idealHeight: 400)` 后追加 `.mainContentCard()`
- 同时将 `agentContent` / `projectContent` / `efficiencyContent` 中 `Text("按 Agent 分解")` 等标题行保留（在卡片外）

**Step 4: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 5: 提交**

```bash
git add token_check/Views/StatsView.swift
git commit -m "feat: 统计页页头整合 + 内容卡片化"
```

---

### Task 8: 主窗口改为 regular 风格

**Files:**
- Modify: `token_check/AppDelegate.swift:59-64`

**Consumes:** 无

**Step 1: 修改 styleMask**

将 `makeMainWindow()` 中的：

```swift
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
```

改为：

```swift
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
```

其余窗口逻辑（隐藏/恢复/激活策略、`MainPanel` 子类）保持不变。

**Step 2: 编译验证**

Run: `xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 3: 手动验证**

启动 app（`open /Applications/token_check.app` 或从 Xcode 运行）：
- 主窗口显示标准标题栏（"Token Check" 大标题），可正常缩放
- 侧边栏 4 个图标可切换页面，选中态为蓝色渐变胶囊
- 费用页：页头（标题+副标题+时间过滤+刷新+回滚）、5 张左对齐统计卡（总费用有 sparkles 强调）、Model 分解卡片含堆叠图与表格
- 趋势页：工具条一行三组 segmented + 刷新，图表在卡片内，chips 在卡片标题栏右侧
- 会话页：搜索框在页头、表格卡片化、行 hover 高亮
- 统计页：页头 + 分段行 + 三套卡片化内容
- 切换系统深浅色模式，各页面颜色正常
- 时间过滤、刷新、回滚开关、搜索均可用

**Step 4: 提交**

```bash
git add token_check/AppDelegate.swift
git commit -m "feat: 主窗口改为 regular 风格"
```

---

## Self-Review 结果

- **Spec 覆盖：** 第 1 节框架（侧边栏 Task 2、页头 Task 2、间距 Task 2/3）✓；第 2 节视觉语言（色彩 Task 1、卡片分层 Task 3、图表容器 Task 4/5、排版 Task 3、动效 Task 3）✓；第 3 节各页面（费用 Task 4、趋势 Task 5、会话 Task 6、统计 Task 7）✓；第 4 节窗口 Task 8 ✓；验证小节 → 各任务编译 + Task 8 手动验证清单 ✓
- **占位符：** 无 TBD/TODO，所有代码块为完整可编译内容
- **类型一致性：** `AppTheme.cost/inputMiss/cacheHit/output/reasoning/rollback`、`surfaceCard`、`sidebarMaterial`、`sidebarSelection` 在 Task 1 定义、Task 3/4/5 引用一致；`StatCardView(emphasized:)` Task 3 定义、Task 4 使用一致；`.mainContentCard()` Task 3 定义、Task 4/5/6/7 使用一致；`ModelBreakdownStackedChart` Task 4 定义与使用一致
