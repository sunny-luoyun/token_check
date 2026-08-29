import SwiftUI
import Combine

struct SettingsView: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    // 注意：API Key 明文存 UserDefaults 是个人工具的已知取舍——
    // 单用户设备 + widget 需跨进程读取，未迁 Keychain（如需分发再迁移）
    @AppStorage("deepseekApiKey") private var deepseekApiKey = ""
    @State private var pricingRules: [ModelPricingRule] = []
    @State private var pricingError: String?
    @State private var isLoadingPricing = false
    @State private var suppressNextPricingSave = false
    @State private var showHiddenPricingRules = false

    @State private var diskUsage: DiskUsage?
    @State private var isLoadingDisk = false
    @State private var isCleaning = false
    @State private var diskError: String?
    @State private var showCleanAlert = false
    @State private var cleanSuccess = false
    @AppStorage("widgetRefreshInterval", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var widgetRefreshInterval = 60
    @AppStorage("widget_dataSource", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var widgetDataSource = "opencode"

    @AppStorage("subscriptionEnabled", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionEnabled = false
    @AppStorage("subscriptionPeriodStart", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionPeriodStart = 0.0
    @AppStorage("subscriptionPeriodDurationDays", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionPeriodDurationDays = 30
    @AppStorage("subscriptionBudget", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionBudget = 60.0
    // 同上：明文存储为已知取舍（个人工具 + widget 跨进程读取）
    @AppStorage("opencodeApiKey", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var opencodeApiKey = ""
    @AppStorage("subscriptionTier", store: UserDefaults(suiteName: "group.com.luoyun.tokencheck")) private var subscriptionTier = 60.0

    @State private var periodRemainingDays = 10
    @State private var periodRemainingHours = 0
    @State private var subscriptionPeriodError: String?
    @State private var now = Date()
    @State private var officialUsage: OpenCodeOfficialUsage?
    @State private var isLoadingOfficialUsage = false

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
                            ForEach(visiblePricingRuleIndices, id: \.self) { index in
                                PricingRuleSection(rule: $pricingRules[index])
                                if index != visiblePricingRuleIndices.last {
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

                        if !hiddenPricingRuleIndices.isEmpty {
                            DisclosureGroup(isExpanded: $showHiddenPricingRules) {
                                VStack(spacing: 0) {
                                    ForEach(hiddenPricingRuleIndices, id: \.self) { index in
                                        HStack(spacing: 8) {
                                            Text(pricingRules[index].displayName)
                                                .font(.caption.weight(.medium))
                                            Spacer()
                                            if !pricingRules[index].usesDefaultPricing {
                                                Text("已自定义")
                                                    .font(.caption2)
                                                    .foregroundStyle(.blue)
                                            }
                                            Button {
                                                pricingRules[index].isHidden = false
                                            } label: {
                                                Image(systemName: "eye")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("恢复显示")
                                        }
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 8)
                                        if index != hiddenPricingRuleIndices.last {
                                            Divider()
                                        }
                                    }
                                }
                            } label: {
                                Text("已隐藏的模型 (\(hiddenPricingRuleIndices.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
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
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("小组件数据源")
                            .font(.subheadline.weight(.medium))
                        Text("小组件统计的数据来源（opencode / DSH / 合并）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $widgetDataSource) {
                        Text("opencode").tag("opencode")
                        Text("DSH").tag("dsh")
                        Text("总").tag("all")
                    }
                    .labelsHidden()
                    .frame(width: 130)
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
                        Text("通过 OpenCode 官方 API 获取准确用量（推荐）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $subscriptionEnabled)
                        .labelsHidden()
                }
                if subscriptionEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        // API Key 输入
                        HStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("OpenCode API Key")
                                    .font(.subheadline.weight(.medium))
                                Text("从 OpenCode 控制台获取（sk-opencode-...）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            SecureField("sk-opencode-...", text: $opencodeApiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                                .frame(width: 280)
                        }

                        // 订阅档位选择
                        HStack(spacing: 12) {
                            Image(systemName: "dollarsign.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("订阅档位")
                                    .font(.subheadline.weight(.medium))
                                Text("用于将百分比转换为金额显示")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $subscriptionTier) {
                                Text("$60/月（标准）").tag(60.0)
                                Text("$200/月（Pro）").tag(200.0)
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }

                        // 官方 API 状态
                        if !opencodeApiKey.isEmpty {
                            if let usage = officialUsage {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.green)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("官方 API 已连接")
                                            .font(.subheadline.weight(.medium))
                                        Text("月度用量 \(usage.monthlyPercent)% · 重置时间 \(formattedResetDate(usage.monthlyResetsAt))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            } else if isLoadingOfficialUsage {
                                HStack(spacing: 12) {
                                    ProgressView()
                                        .frame(width: 28)
                                    Text("正在验证 API Key…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            } else {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.orange)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("API Key 验证失败")
                                            .font(.subheadline.weight(.medium))
                                        Text("请检查 Key 是否正确（格式：sk-opencode-...）")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }

                        // 向后兼容：手动模式
                        DisclosureGroup("高级：手动模式（不使用官方 API）") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    Image(systemName: "calendar.day.fill")
                                        .font(.title2)
                                        .foregroundStyle(.purple)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("周期总长")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    Spacer()
                                    TextField("", value: $subscriptionPeriodDurationDays, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption.monospaced())
                                        .frame(width: 60)
                                    Text("天")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 12) {
                                    Image(systemName: "hourglass")
                                        .font(.title2)
                                        .foregroundStyle(.purple)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("当前剩余")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    Spacer()
                                    TextField("", value: $periodRemainingDays, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption.monospaced())
                                        .frame(width: 50)
                                    Text("天")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextField("", value: $periodRemainingHours, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption.monospaced())
                                        .frame(width: 40)
                                    Text("时")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("保存校准") {
                                        saveSubscriptionPeriod()
                                    }
                                    .buttonStyle(.bordered)
                                }
                                if let err = subscriptionPeriodError {
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .padding(.leading, 40)
                                }
                                HStack(spacing: 12) {
                                    Image(systemName: "dollarsign.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.purple)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("月度额度")
                                            .font(.subheadline.weight(.medium))
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
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 2)
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
            validateOpenCodeApiKey()
        }
        .onChange(of: opencodeApiKey) { _, newValue in
            validateOpenCodeApiKey()
        }
        .onChange(of: pricingRules) { _, _ in
            // 加载流程通过赋值 pricingRules 也会触发本回调；此时禁止回写，
            // 否则「读失败→用默认撑满→立刻写回」会把用户自定义价格覆盖成默认并固化。
            // 注意：这里只判断、不主动复位——复位交给 loadPricingRules 内的延迟兜底，
            // 避免「加载后值未变化 → onChange 不触发 → 标志残留吞掉用户首次编辑」。
            if suppressNextPricingSave {
                return
            }
            savePricingRules()
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { newNow in
            now = newNow
        }
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

    private func validateOpenCodeApiKey() {
        guard !opencodeApiKey.isEmpty else {
            officialUsage = nil
            return
        }
        isLoadingOfficialUsage = true
        Task {
            let usage = await OpenCodeUsageService.shared.fetchUsage(apiKey: opencodeApiKey)
            await MainActor.run {
                self.officialUsage = usage
                self.isLoadingOfficialUsage = false
            }
        }
    }

    private func formattedResetDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }

    private func saveSubscriptionPeriod() {
        subscriptionPeriodError = nil
        let durationDays = subscriptionPeriodDurationDays
        guard durationDays >= 1 else {
            subscriptionPeriodError = "周期总长至少 1 天"
            return
        }
        guard periodRemainingDays >= 0, periodRemainingHours >= 0, periodRemainingHours <= 23 else {
            subscriptionPeriodError = "剩余小时需在 0–23 之间"
            return
        }
        let totalHours = durationDays * 24
        let remainingHours = periodRemainingDays * 24 + periodRemainingHours
        guard remainingHours <= totalHours else {
            subscriptionPeriodError = "剩余时长不能超过周期总长"
            return
        }
        let nowDate = Date()
        let start = nowDate.addingTimeInterval(-TimeInterval(totalHours - remainingHours) * 3600)
        let startMs = floor(start.timeIntervalSince1970 / 3600) * 3600 * 1000
        subscriptionPeriodStart = startMs
        now = nowDate
    }

    // MARK: - Pricing Rule Section

    private struct PricingRuleSection: View {
        @Binding var rule: ModelPricingRule
        @State private var isExpanded = false
        @State private var addWindowPeriodId: String?
        @State private var newWindowLabel = ""
        @State private var newWindowStart = 0
        @State private var newWindowEnd = 8

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
                        Button {
                            rule.isHidden = true
                        } label: {
                            Image(systemName: "eye.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("隐藏该模型")
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
                            PricingPeriodEditor(period: $period, addWindowPeriodId: $addWindowPeriodId, newWindowLabel: $newWindowLabel, newWindowStart: $newWindowStart, newWindowEnd: $newWindowEnd, onDelete: {
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

        /// 价格格式化：最多 6 位小数，去掉多余的尾零（如 0.140000 → 0.14）
        private static func formatPrice(_ value: Double) -> String {
            let formatted = String(format: "%.6f", value)
            var trimmed = formatted
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }

        private var currentPriceSummary: String {
            let now = Date.now
            let prices = rule.price(at: now)
            let df = DateFormatter()
            df.dateFormat = "MM-dd"
            let active = rule.periods.first { now >= $0.effectiveFrom && ($0.effectiveTo == nil || now < $0.effectiveTo!) }
            var summary = "输入 $\(Self.formatPrice(prices.inputMiss)) / 缓存 $\(Self.formatPrice(prices.cacheHit)) / 输出 $\(Self.formatPrice(prices.output))"
            if let active = active, let windows = active.timeWindows, !windows.isEmpty {
                let hour = Calendar.current.component(.hour, from: now)
                if let w = windows.first(where: { hour >= $0.startHour && hour < $0.endHour }) {
                    summary += " · \(w.label)"
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
                            VStack(spacing: 2) {
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

                                    Spacer()

                                    Button {
                                        period.timeWindows?.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                HStack(spacing: 6) {
                                    priceField(label: "无缓存输入", value: Binding(
                                        get: { period.timeWindows?[idx].inputMissPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].inputMissPricePerMillion = $0 }
                                    ))
                                    priceField(label: "缓存命中", value: Binding(
                                        get: { period.timeWindows?[idx].cacheHitPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].cacheHitPricePerMillion = $0 }
                                    ))
                                    priceField(label: "输出", value: Binding(
                                        get: { period.timeWindows?[idx].outputPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].outputPricePerMillion = $0 }
                                    ))
                                    priceField(label: "推理", value: Binding(
                                        get: { period.timeWindows?[idx].reasoningPricePerMillion ?? 0 },
                                        set: { period.timeWindows?[idx].reasoningPricePerMillion = $0 }
                                    ))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 2)
                }

                if addWindowPeriodId == period.id {
                    addWindowForm()
                } else {
                    Button {
                        addWindowPeriodId = period.id
                        newWindowLabel = ""
                        newWindowStart = 0
                        newWindowEnd = 8
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
                TextField("", value: value, format: .number.precision(.fractionLength(0...6)))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 96)
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

        private func addWindowForm() -> some View {
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
                Button("添加") {
                    let label = newWindowLabel.trimmingCharacters(in: .whitespaces)
                    period.timeWindows = period.timeWindows ?? []
                    period.timeWindows?.append(TimeWindow(
                        label: label.isEmpty ? "窗口" : label,
                        startHour: newWindowStart,
                        endHour: newWindowEnd,
                        inputMissPricePerMillion: period.inputMissPricePerMillion,
                        cacheHitPricePerMillion: period.cacheHitPricePerMillion,
                        outputPricePerMillion: period.outputPricePerMillion,
                        reasoningPricePerMillion: period.reasoningPricePerMillion
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

        // 区分「未配置」「文件损坏」「读取成功」：损坏时禁止用默认值撑满后回写，保护用户自定义价格
        let savedRules: [ModelPricingRule]
        let loadFailed: Bool
        switch ModelPricingStore.loadResult() {
        case .success(let rules):
            savedRules = rules
            loadFailed = false
        case .notFound:
            savedRules = []
            loadFailed = false
        case .corrupted:
            savedRules = []
            loadFailed = true
        }
        let savedLookup = Dictionary(uniqueKeysWithValues: savedRules.map { ($0.pricingKey, $0) })

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = try DatabaseService()
                let models = try service.fetchModelUsage().map {
                    savedLookup[$0.id] ?? .defaults(providerID: $0.providerID, modelId: $0.modelId, variant: $0.variant)
                }
                // 合并 DSH 数据源出现过的模型（默认路由 + 事件级），
                // 让只走 DeepSeek Harness / 中转站的模型也能在设置里配置价格
                let merged = Self.mergePricingRules(models: models + Self.dshModels(), savedRules: savedRules)

                DispatchQueue.main.async {
                    self.suppressNextPricingSave = true
                    self.pricingRules = merged
                    if loadFailed {
                        self.pricingError = "价格配置文件读取失败，为避免覆盖已使用默认值。请手动恢复默认价格后重新设置。"
                    }
                    self.isLoadingPricing = false
                    // 兜底复位：本次加载若未改变 pricingRules（onChange 不触发），延迟复位避免残留吞掉后续首次编辑
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.suppressNextPricingSave = false
                    }
                }
            } catch {
                let merged = Self.mergePricingRules(models: Self.dshModels(), savedRules: savedRules)
                DispatchQueue.main.async {
                    self.suppressNextPricingSave = true
                    self.pricingRules = merged
                    self.pricingError = merged.isEmpty ? error.localizedDescription : nil
                    self.isLoadingPricing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.suppressNextPricingSave = false
                    }
                }
            }
        }
    }

    /// 枚举 DSH 数据源出现过的模型：默认模型路由（settings.yaml agent-default-model）+
    /// 事件级模型（~/.dsh/sessions 的 provider/model）。用于合并进「模型价格」设置列表。
    private static func dshModels() -> [ModelPricingRule] {
        guard case .success(let dataSource) = DshService.shared.loadDetailedData() else { return [] }

        var seen = Set<String>()
        var result: [ModelPricingRule] = []
        func add(_ providerID: String, _ modelId: String, _ variant: String) {
            let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id != "unknown" else { return }
            let key = "\(providerID)/\(id)/\(variant)"
            guard seen.insert(key).inserted else { return }
            result.append(.defaults(providerID: providerID, modelId: id, variant: variant))
        }

        // 默认模型路由（settings.yaml agent-default-model），L1 回退时也能配置价格
        let dm = dataSource.defaultModel
        add(dm.providerID, dm.modelId, dm.variant)

        // 事件级模型（L2 full：实际调用过的 provider/model）
        for event in dataSource.events {
            add(event.providerID, event.modelId, "default")
        }
        return result
    }

    private func savePricingRules() {
        ModelPricingStore.save(pricingRules)
    }

    private var visiblePricingRuleIndices: [Int] {
        pricingRules.indices.filter { !pricingRules[$0].isHidden }
    }

    private var hiddenPricingRuleIndices: [Int] {
        pricingRules.indices.filter { pricingRules[$0].isHidden }
    }

    private func resetAllPricing() {
        pricingRules = pricingRules.map {
            var rule = ModelPricingRule.defaults(providerID: $0.providerID, modelId: $0.modelId, variant: $0.variant)
            rule.isEnabled = $0.isEnabled
            rule.isHidden = $0.isHidden
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
        ("cacheHitRate", "缓存命中率"),
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
        ("cacheHitRate", "缓存命中率"),
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

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text("DSH 数据")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            DiskUsageRow(icon: "externaldrive.fill", label: "数据大小", value: usage.dshFileSize)
            DiskUsageRow(icon: "rectangle.stack.fill", label: "会话记录", value: dshSessionText)
            DiskUsageRow(icon: "text.bubble.fill",     label: "消息记录", value: dshMessageText)
            DiskUsageRow(icon: "doc.text.fill",        label: "事件日志", value: dshEventText)
        }
        .padding(.vertical, 4)
    }

    /// 会话数按 sessions/ 目录计数，不依赖 zstd
    private var dshSessionText: String { "\(usage.dshSessionCount) 条" }
    private var dshMessageText: String {
        usage.dshMessageCount > 0 ? "\(usage.dshMessageCount) 条" : "—"
    }
    private var dshEventText: String {
        usage.dshEventCount > 0 ? "\(usage.dshEventCount) 条" : "—"
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
