import SwiftUI

struct SettingsView: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("deepseekApiKey") private var deepseekApiKey = ""
    @State private var pricingRules: [ModelPricingRule] = []
    @State private var pricingError: String?
    @State private var isLoadingPricing = false

    @State private var diskUsage: DiskUsage?
    @State private var isLoadingDisk = false
    @State private var isCleaning = false
    @State private var diskError: String?
    @State private var showCleanAlert = false
    @State private var cleanSuccess = false
    @AppStorage("widgetRefreshInterval", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var widgetRefreshInterval = 60

    @AppStorage("subscriptionEnabled", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionEnabled = false
    @AppStorage("subscriptionStartDay", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionStartDay = 15
    @AppStorage("subscriptionBudget", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionBudget = 60.0

    @Environment(\.appTheme) var theme

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "eye")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    Toggle("显示 Dock 图标", isOn: $showDockIcon)
                }
                .onChange(of: showDockIcon) { _, newValue in
                    if newValue {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        return
                    }

                    let appDelegate = NSApp.delegate as? AppDelegate
                    let hasVisibleMainWindow = appDelegate?.mainPanelController?.hasVisibleMainWindow() == true
                    NSApp.setActivationPolicy(hasVisibleMainWindow ? .regular : .accessory)
                }
                HStack {
                    Image(systemName: "menubar.dock.rectangle")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)
                }
            } header: {
                settingsHeader(icon: "paintbrush.fill", title: "外观", color: .purple)
            }

            Section {
                HStack {
                    Image(systemName: "key.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                    SecureField("DeepSeek API Key", text: $deepseekApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .disableAutocorrection(true)
                }
                HStack {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("用于在小组件中显示账户余额。Key 仅存在本地，不会上传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 36)
            } header: {
                settingsHeader(icon: "dollarsign.circle.fill", title: "DeepSeek", color: .orange)
            }

            Section {
                if isLoadingPricing {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView("正在加载模型…")
                        Spacer()
                    }
                    .frame(height: 80)
                } else if let pricingError {
                    Text(pricingError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if pricingRules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("还没有读取到模型记录，先使用一下模型再回来设置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("按模型 ID + variant 分别配置。价格单位：美元 / 百万 token。可设置多个时间段和分时折扣。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复全部默认价格", action: resetAllPricing)
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }

                        VStack(spacing: 0) {
                            ForEach(Array($pricingRules.enumerated()), id: \.element.id) { index, $rule in
                                PricingRuleSection(rule: $rule)
                                if index < pricingRules.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .fill(.background)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .stroke(.separator.opacity(0.2), lineWidth: 1)
                        )
                    }
                }
            } header: {
                HStack {
                    settingsHeader(icon: "tablecells.fill", title: "模型价格", color: .blue)
                    Spacer()
                }
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("桌面小组件")
                            .font(.subheadline.weight(.medium))
                        Text("菜单栏点击「移动」可拖拽，再点「固定」锁定")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "timer")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("数据刷新间隔")
                            .font(.subheadline.weight(.medium))
                        Picker("", selection: $widgetRefreshInterval) {
                            Text("1 分钟").tag(60)
                            Text("2 分钟").tag(120)
                            Text("5 分钟").tag(300)
                            Text("10 分钟").tag(600)
                            Text("15 分钟").tag(900)
                            Text("30 分钟").tag(1800)
                        }
                        .labelsHidden()
                    }
                }
                MenuBarStatPicker(
                    label: "菜单栏第一项统计",
                    key: "widgetStat1",
                    defaultVal: "inputTokens"
                )
                MenuBarStatPicker(
                    label: "菜单栏第二项统计",
                    key: "widgetStat2",
                    defaultVal: "cacheReadTokens"
                )
                MenuBarStatPicker(
                    label: "菜单栏第三项统计",
                    key: "widgetStat3",
                    defaultVal: "outputTokens"
                )
                MenuBarStatPicker(
                    label: "菜单栏第四项统计",
                    key: "widgetStat4",
                    defaultVal: "sessionCount"
                )
                WidgetStatPicker(
                    label: "小组件第一项统计",
                    key: "widget_stat_1",
                    defaultVal: "inputTokens"
                )
                WidgetStatPicker(
                    label: "小组件第二项统计",
                    key: "widget_stat_2",
                    defaultVal: "cacheReadTokens"
                )
                WidgetStatPicker(
                    label: "小组件第三项统计",
                    key: "widget_stat_3",
                    defaultVal: "outputTokens"
                )
                WidgetStatPicker(
                    label: "小组件第四项统计",
                    key: "widget_stat_4",
                    defaultVal: "sessionCount"
                )
            } header: {
                settingsHeader(icon: "square.grid.2x2.fill", title: "桌面小组件", color: .green)
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.title2)
                        .foregroundStyle(.indigo)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("大组件配置")
                            .font(.subheadline.weight(.medium))
                        Text("也可在桌面右键大组件 → 编辑小组件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LargeWidgetStatPicker(
                    label: "大组件指标1",
                    key: "large_widget_stat_1",
                    defaultVal: "inputTokens"
                )
                LargeWidgetStatPicker(
                    label: "大组件指标2",
                    key: "large_widget_stat_2",
                    defaultVal: "cacheReadTokens"
                )
                LargeWidgetStatPicker(
                    label: "大组件指标3",
                    key: "large_widget_stat_3",
                    defaultVal: "outputTokens"
                )
                LargeWidgetStatPicker(
                    label: "大组件指标4",
                    key: "large_widget_stat_4",
                    defaultVal: "sessionCount"
                )
                LargeWidgetChartRangePicker()
            } header: {
                settingsHeader(icon: "rectangle.split.3x1.fill", title: "大组件", color: .indigo)
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "creditcard.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启订阅计费统计")
                            .font(.subheadline.weight(.medium))
                        Text("统计 opencode-go 提供商在订阅周期内的消耗")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $subscriptionEnabled)
                        .labelsHidden()
                }
                if subscriptionEnabled {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.day.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("扣费日")
                                .font(.subheadline.weight(.medium))
                            Text("每月扣费日，周期为一个自然月")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $subscriptionStartDay) {
                            ForEach(1...28, id: \.self) { day in
                                Text("每月 \(day) 日").tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("月度额度")
                                .font(.subheadline.weight(.medium))
                            Text("每月总预算额度")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Text("$")
                                .foregroundStyle(.secondary)
                            TextField("", value: $subscriptionBudget, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                                .frame(width: 80)
                        }
                    }
                }
            } header: {
                settingsHeader(icon: "chart.pie.fill", title: "订阅计费", color: .purple)
            }

            Section {
                if isLoadingDisk {
                    HStack {
                        Spacer()
                        ProgressView("正在读取…")
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else if let diskError {
                    Text(diskError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let diskUsage {
                    DiskUsageDetailView(usage: diskUsage)

                    if cleanSuccess {
                        Label("清理完成！磁盘空间已释放。", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .padding(.leading, 36)
                    }

                    if isCleaning {
                        HStack {
                            Spacer()
                            ProgressView("正在清理…")
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        Button("清理历史消息（保留统计数据）") {
                            showCleanAlert = true
                        }
                        .disabled(isCleaning)
                        .alert("确认清理", isPresented: $showCleanAlert) {
                            Button("取消", role: .cancel) {}
                            Button("确认清理", role: .destructive) {
                                performCleanup()
                            }
                        } message: {
                            Text("历史消息删除后无法恢复。\n会话记录和 token 统计不会受影响。")
                        }

                        HStack {
                            Image(systemName: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("仅删除对话内容，tokens / cost 等统计数据不变")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 36)
                    }
                }
            } header: {
                settingsHeader(icon: "internaldrive.fill", title: "磁盘用量", color: .cyan)
            }
        }
        .onAppear {
            loadPricingRules()
            loadDiskInfo()
        }
        .onChange(of: pricingRules) {
            savePricingRules()
        }
        .formStyle(.grouped)
        .frame(width: 820, height: 700)
    }

    private func settingsHeader(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Pricing Rule Section

    private struct PricingRuleSection: View {
        @Binding var rule: ModelPricingRule
        @State private var isExpanded = false
        @State private var addWindowPeriodId: String?
        @State private var newWindowLabel = ""
        @State private var newWindowStart = 0
        @State private var newWindowEnd = 8
        @State private var newWindowMultiplier = 0.5

        var body: some View {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.displayName)
                                .font(.caption.weight(.medium))
                            if isExpanded {
                                Text(currentPriceSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: $rule.isEnabled)
                            .labelsHidden()
                            .scaleEffect(0.8)
                        if !rule.usesDefaultPricing {
                            Text("已自定义")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                if isExpanded {
                    Divider()
                        .padding(.horizontal, 4)

                    VStack(spacing: 6) {
                        ForEach(Array($rule.periods.enumerated()), id: \.element.id) { idx, $period in
                            PricingPeriodEditor(period: $period, addWindowPeriodId: $addWindowPeriodId, newWindowLabel: $newWindowLabel, newWindowStart: $newWindowStart, newWindowEnd: $newWindowEnd, newWindowMultiplier: $newWindowMultiplier, onDelete: {
                                rule.periods.remove(at: idx)
                            })
                            if idx < rule.periods.count - 1 {
                                Divider()
                                    .padding(.leading, 12)
                            }
                        }

                        Button {
                            let cal = Calendar.current
                            let today = cal.startOfDay(for: Date())
                            rule.periods.append(PricingPeriod(
                                label: "新时间段",
                                effectiveFrom: today,
                                effectiveTo: nil,
                                inputMissPricePerMillion: ModelPricingRule.defaultInputMissPricePerMillion,
                                cacheHitPricePerMillion: ModelPricingRule.defaultCacheHitPricePerMillion,
                                outputPricePerMillion: ModelPricingRule.defaultOutputPricePerMillion,
                                reasoningPricePerMillion: ModelPricingRule.defaultReasoningPricePerMillion,
                                timeWindows: nil
                            ))
                        } label: {
                            Label("新增时间段", systemImage: "plus.circle")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                }
            }
        }

        private var currentPriceSummary: String {
            let now = Date.now
            let prices = rule.price(at: now)
            let df = DateFormatter()
            df.dateFormat = "MM-dd"
            let active = rule.periods.first { now >= $0.effectiveFrom && ($0.effectiveTo == nil || now < $0.effectiveTo!) }
            var summary = "输入 $\(String(format: "%.2f", prices.inputMiss)) / 缓存 $\(String(format: "%.4f", prices.cacheHit)) / 输出 $\(String(format: "%.2f", prices.output))"
            if let active = active, let windows = active.timeWindows, !windows.isEmpty {
                let hour = Calendar.current.component(.hour, from: now)
                if let w = windows.first(where: { hour >= $0.startHour && hour < $0.endHour }) {
                    summary += " · \(w.label)(x\(String(format: "%.2f", w.priceMultiplier)))"
                }
            }
            if let active = active, active.effectiveFrom > Date.distantPast {
                summary += " · 自 \(df.string(from: active.effectiveFrom))"
            }
            return summary
        }
    }

    // MARK: - Pricing Period Editor

    private struct PricingPeriodEditor: View {
        @Binding var period: PricingPeriod
        @Binding var addWindowPeriodId: String?
        @Binding var newWindowLabel: String
        @Binding var newWindowStart: Int
        @Binding var newWindowEnd: Int
        @Binding var newWindowMultiplier: Double
        let onDelete: () -> Void

        var body: some View {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    TextField("标签", text: $period.label)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 100)

                    Text("生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $period.effectiveFrom, displayedComponents: .date)
                        .labelsHidden()
                        .scaleEffect(0.85)
                        .frame(width: 100)

                    if let to = period.effectiveTo {
                        Text("至")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("", selection: Binding(
                            get: { to },
                            set: { period.effectiveTo = $0 }
                        ), displayedComponents: .date)
                            .labelsHidden()
                            .scaleEffect(0.85)
                            .frame(width: 100)
                        Button {
                            period.effectiveTo = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button("设截止日") {
                            period.effectiveTo = Calendar.current.startOfDay(for: Date())
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }

                    Spacer()

                    Button("删除", action: onDelete)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 6) {
                    priceField(label: "无缓存输入", value: $period.inputMissPricePerMillion)
                    priceField(label: "缓存命中", value: $period.cacheHitPricePerMillion)
                    priceField(label: "输出", value: $period.outputPricePerMillion)
                    priceField(label: "推理", value: $period.reasoningPricePerMillion)
                }

                if let windows = period.timeWindows, !windows.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { idx, _ in
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("标签", text: Binding(
                                    get: { period.timeWindows?[idx].label ?? "" },
                                    set: { period.timeWindows?[idx].label = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .frame(width: 70)

                                hourStepper(value: Binding(
                                    get: { period.timeWindows?[idx].startHour ?? 0 },
                                    set: { period.timeWindows?[idx].startHour = $0 }
                                ), label: "开始")

                                Text("→")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                hourStepper(value: Binding(
                                    get: { period.timeWindows?[idx].endHour ?? 24 },
                                    set: { period.timeWindows?[idx].endHour = $0 }
                                ), label: "结束")

                                TextField("倍率", value: Binding(
                                    get: { period.timeWindows?[idx].priceMultiplier ?? 1.0 },
                                    set: { period.timeWindows?[idx].priceMultiplier = $0 }
                                ), format: .number.precision(.fractionLength(0...2)))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .frame(width: 56)

                                Button {
                                    period.timeWindows?.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 2)
                }

                if addWindowPeriodId == period.id {
                    addWindowForm(periodId: period.id)
                } else {
                    Button {
                        addWindowPeriodId = period.id
                        newWindowLabel = ""
                        newWindowStart = 0
                        newWindowEnd = 8
                        newWindowMultiplier = 0.5
                    } label: {
                        Label("添加分时窗口", systemImage: "plus")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }

        private func priceField(label: String, value: Binding<Double>) -> some View {
            HStack(spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                TextField("", value: value, format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 80)
            }
        }

        private func hourStepper(value: Binding<Int>, label: String) -> some View {
            HStack(spacing: 2) {
                Button {
                    if value.wrappedValue > 0 { value.wrappedValue -= 1 }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text("\(String(format: "%02d", value.wrappedValue)):00")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)
                Button {
                    if value.wrappedValue < 24 { value.wrappedValue += 1 }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }

        private func addWindowForm(periodId: String) -> some View {
            HStack(spacing: 4) {
                TextField("标签", text: $newWindowLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 70)
                hourStepper(value: $newWindowStart, label: "开始")
                Text("→")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                hourStepper(value: $newWindowEnd, label: "结束")
                TextField("倍率", value: $newWindowMultiplier, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 56)
                Button("添加") {
                    let label = newWindowLabel.trimmingCharacters(in: .whitespaces)
                    period.timeWindows = period.timeWindows ?? []
                    period.timeWindows?.append(TimeWindow(
                        label: label.isEmpty ? "窗口" : label,
                        startHour: newWindowStart,
                        endHour: newWindowEnd,
                        priceMultiplier: newWindowMultiplier
                    ))
                    addWindowPeriodId = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
                Button("取消") {
                    addWindowPeriodId = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Load / Save / Reset

    private func loadPricingRules() {
        isLoadingPricing = true
        pricingError = nil

        let savedRules = ModelPricingStore.load()
        let savedLookup = Dictionary(uniqueKeysWithValues: savedRules.map { ($0.pricingKey, $0) })

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = try DatabaseService()
                let models = try service.fetchModelUsage().map {
                    savedLookup[$0.id] ?? .defaults(providerID: $0.providerID, modelId: $0.modelId, variant: $0.variant)
                }
                let merged = Self.mergePricingRules(models: models, savedRules: savedRules)

                DispatchQueue.main.async {
                    self.pricingRules = merged
                    self.isLoadingPricing = false
                }
            } catch {
                let merged = Self.mergePricingRules(models: [], savedRules: savedRules)
                DispatchQueue.main.async {
                    self.pricingRules = merged
                    self.pricingError = merged.isEmpty ? error.localizedDescription : nil
                    self.isLoadingPricing = false
                }
            }
        }
    }

    private func savePricingRules() {
        ModelPricingStore.save(pricingRules)
    }

    private func resetAllPricing() {
        pricingRules = pricingRules.map {
            var rule = ModelPricingRule.defaults(providerID: $0.providerID, modelId: $0.modelId, variant: $0.variant)
            rule.isEnabled = $0.isEnabled
            return rule
        }
    }

    private static func mergePricingRules(models: [ModelPricingRule], savedRules: [ModelPricingRule]) -> [ModelPricingRule] {
        var merged: [String: ModelPricingRule] = Dictionary(uniqueKeysWithValues: savedRules.map { ($0.pricingKey, $0) })
        for rule in models {
            merged[rule.pricingKey] = merged[rule.pricingKey] ?? rule
        }
        return merged.values.sorted {
            if $0.providerID == $1.providerID {
                if $0.modelId == $1.modelId {
                    return $0.variant < $1.variant
                }
                return $0.modelId < $1.modelId
            }
            return $0.providerID < $1.providerID
        }
    }

    // MARK: - 磁盘用量

    private func loadDiskInfo() {
        isLoadingDisk = true
        diskError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = DiskCleanupService()
                let usage = try service.fetchDiskUsage()
                DispatchQueue.main.async {
                    self.diskUsage = usage
                    self.isLoadingDisk = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.diskError = error.localizedDescription
                    self.isLoadingDisk = false
                }
            }
        }
    }

    private func performCleanup() {
        isCleaning = true
        cleanSuccess = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = DiskCleanupService()
                try service.cleanupMessages()
                let refreshed = try service.fetchDiskUsage()
                DispatchQueue.main.async {
                    self.diskUsage = refreshed
                    self.isCleaning = false
                    self.cleanSuccess = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCleaning = false
                    self.diskError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 小组件统计项选择器（写入 App Group UserDefaults）

private struct WidgetStatPicker: View {
    let label: String
    let key: String
    let defaultVal: String
    @State private var selection: String

    init(label: String, key: String, defaultVal: String) {
        self.label = label
        self.key = key
        self.defaultVal = defaultVal
        _selection = State(initialValue: UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.string(forKey: key) ?? defaultVal)
    }

    private static let allStats: [(tag: String, display: String)] = [
        ("inputTokens", "输入 Token"),
        ("outputTokens", "输出 Token"),
        ("reasoningTokens", "推理 Token"),
        ("cacheReadTokens", "缓存读取"),
        ("cacheWriteTokens", "缓存写入"),
        ("totalTokens", "总 Token"),
        ("todayCost", "今日费用"),
        ("sessionCount", "会话数"),
        ("messageCount", "消息数"),
        ("projectCount", "项目数"),
        ("additions", "新增行数"),
        ("deletions", "删除行数"),
        ("files", "变更文件"),
        ("netAdditions", "净增行数"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Picker("", selection: $selection) {
                    ForEach(Self.allStats, id: \.tag) { stat in
                        Text(stat.display).tag(stat.tag)
                    }
                }
                .labelsHidden()
                .onChange(of: selection) { _, newValue in
                    UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.set(newValue, forKey: key)
                }
            }
        }
    }
}

// MARK: - 大组件统计项选择器

private struct LargeWidgetStatPicker: View {
    let label: String
    let key: String
    let defaultVal: String
    @State private var selection: String

    init(label: String, key: String, defaultVal: String) {
        self.label = label
        self.key = key
        self.defaultVal = defaultVal
        _selection = State(initialValue: UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.string(forKey: key) ?? defaultVal)
    }

    private static let allStats: [(tag: String, display: String)] = [
        ("inputTokens", "输入"),
        ("outputTokens", "输出"),
        ("reasoningTokens", "推理"),
        ("cacheReadTokens", "缓存"),
        ("cacheWriteTokens", "缓存写入"),
        ("totalTokens", "总计"),
        ("todayCost", "费用"),
        ("sessionCount", "会话"),
        ("messageCount", "消息"),
        ("projectCount", "项目"),
        ("additions", "新增"),
        ("deletions", "删除"),
        ("files", "文件"),
        ("netAdditions", "净增"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal.fill")
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Picker("", selection: $selection) {
                    ForEach(Self.allStats, id: \.tag) { stat in
                        Text(stat.display).tag(stat.tag)
                    }
                }
                .labelsHidden()
                .onChange(of: selection) { _, newValue in
                    UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.set(newValue, forKey: key)
                }
            }
        }
    }
}

private struct LargeWidgetChartRangePicker: View {
    @State private var selection: String

    init() {
        _selection = State(initialValue: UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.string(forKey: "large_widget_chart_range") ?? "7d")
    }

    private static let allRanges: [(tag: String, display: String)] = [
        ("7d", "近7天"),
        ("30d", "近30天"),
        ("1h", "当天分时"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("图表范围")
                    .font(.subheadline.weight(.medium))
                Picker("", selection: $selection) {
                    ForEach(Self.allRanges, id: \.tag) { range in
                        Text(range.display).tag(range.tag)
                    }
                }
                .labelsHidden()
                .onChange(of: selection) { _, newValue in
                    UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.set(newValue, forKey: "large_widget_chart_range")
                }
            }
        }
    }
}

// MARK: - 菜单栏统计项选择器

private struct MenuBarStatPicker: View {
    let label: String
    let key: String
    let defaultVal: String
    @State private var selection: String

    init(label: String, key: String, defaultVal: String) {
        self.label = label
        self.key = key
        self.defaultVal = defaultVal
        _selection = State(initialValue: UserDefaults.standard.string(forKey: key) ?? defaultVal)
    }

    private static let allStats: [(tag: String, display: String)] = [
        ("inputTokens", "输入 Token"),
        ("outputTokens", "输出 Token"),
        ("reasoningTokens", "推理 Token"),
        ("cacheReadTokens", "缓存读取"),
        ("cacheWriteTokens", "缓存写入"),
        ("totalTokens", "总 Token"),
        ("todayCost", "今日费用"),
        ("sessionCount", "会话数"),
        ("messageCount", "消息数"),
        ("projectCount", "项目数"),
        ("additions", "新增行数"),
        ("deletions", "删除行数"),
        ("files", "变更文件"),
        ("netAdditions", "净增行数"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("菜单栏\(label)")
                    .font(.subheadline.weight(.medium))
                Picker("", selection: $selection) {
                    ForEach(Self.allStats, id: \.tag) { stat in
                        Text(stat.display).tag(stat.tag)
                    }
                }
                .labelsHidden()
                .onChange(of: selection) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: key)
                }
            }
        }
    }
}

// MARK: - 磁盘用量子视图

private struct DiskUsageDetailView: View {
    let usage: DiskUsage

    var body: some View {
        VStack(spacing: 8) {
            DiskUsageRow(icon: "externaldrive.fill", label: "数据库文件", value: usage.dbFileSize)
            DiskUsageRow(icon: "rectangle.stack.fill", label: "会话记录",   value: "\(usage.sessionCount) 条")
            DiskUsageRow(icon: "text.bubble.fill",     label: "消息记录",   value: "\(usage.messageCount) 条")
            DiskUsageRow(icon: "doc.text.fill",        label: "事件日志",   value: "\(usage.eventCount) 条")
        }
        .padding(.vertical, 4)
    }
}

private struct DiskUsageRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
