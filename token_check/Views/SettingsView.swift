import SwiftUI

struct SettingsView: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("deepseekApiKey") private var deepseekApiKey = ""
    @State private var pricingRules: [ModelPricingRule] = []
    @State private var pricingError: String?
    @State private var isLoadingPricing = false

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
                            Text("按模型 ID + variant 分别配置。价格单位：元 / 百万 token。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复全部默认价格", action: resetAllPricing)
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }

                        VStack(spacing: 0) {
                            GridRowHeader
                                .padding(.vertical, 8)
                                .padding(.horizontal, 4)

                            Divider()

                            ForEach(Array($pricingRules.enumerated()), id: \.element.id) { index, $rule in
                                PricingRuleRow(rule: $rule, onReset: { resetPricing(for: rule.pricingKey) })
                                if index < pricingRules.count - 1 {
                                    Divider()
                                        .padding(.leading, 4)
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
            } header: {
                settingsHeader(icon: "square.grid.2x2.fill", title: "桌面小组件", color: .green)
            }
        }
        .onAppear(perform: loadPricingRules)
        .onChange(of: pricingRules) {
            savePricingRules()
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 520)
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

    private var GridRowHeader: some View {
        HStack(spacing: 8) {
            Text("模型")
                .font(.caption.bold())
                .frame(width: 140, alignment: .leading)
            Text("启用")
                .font(.caption.bold())
                .frame(width: 40)
            Text("输入（无缓存）")
                .font(.caption.bold())
                .frame(width: 90)
            Text("输入（有缓存）")
                .font(.caption.bold())
                .frame(width: 90)
            Text("输出")
                .font(.caption.bold())
                .frame(width: 90)
            Spacer()
        }
    }

    private struct PricingRuleRow: View {
        @Binding var rule: ModelPricingRule
        let onReset: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayName)
                        .font(.caption.weight(.medium))
                    if !rule.usesDefaultPricing {
                        Text("已自定义")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                .frame(width: 140, alignment: .leading)

                Toggle("", isOn: $rule.isEnabled)
                    .labelsHidden()
                    .frame(width: 40)

                TextField("", value: $rule.inputMissPricePerMillion, format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!rule.isEnabled)
                    .frame(width: 90)

                TextField("", value: $rule.cacheHitPricePerMillion, format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!rule.isEnabled)
                    .frame(width: 90)

                TextField("", value: $rule.outputPricePerMillion, format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!rule.isEnabled)
                    .frame(width: 90)

                Button("默认", action: onReset)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    private func loadPricingRules() {
        isLoadingPricing = true
        pricingError = nil

        let savedRules = ModelPricingStore.load()
        let savedLookup = Dictionary(uniqueKeysWithValues: savedRules.map { ($0.pricingKey, $0) })

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = try DatabaseService()
                let models = try service.fetchModelUsage().map {
                    savedLookup[$0.id] ?? .defaults(modelId: $0.modelId, variant: $0.variant)
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
            var rule = ModelPricingRule.defaults(modelId: $0.modelId, variant: $0.variant)
            rule.isEnabled = $0.isEnabled
            return rule
        }
    }

    private func resetPricing(for key: String) {
        guard let index = pricingRules.firstIndex(where: { $0.pricingKey == key }) else { return }
        let isEnabled = pricingRules[index].isEnabled
        pricingRules[index] = .defaults(modelId: pricingRules[index].modelId, variant: pricingRules[index].variant)
        pricingRules[index].isEnabled = isEnabled
    }

    private static func mergePricingRules(models: [ModelPricingRule], savedRules: [ModelPricingRule]) -> [ModelPricingRule] {
        var merged: [String: ModelPricingRule] = Dictionary(uniqueKeysWithValues: savedRules.map { ($0.pricingKey, $0) })
        for rule in models {
            merged[rule.pricingKey] = merged[rule.pricingKey] ?? rule
        }
        return merged.values.sorted {
            if $0.modelId == $1.modelId {
                return $0.variant < $1.variant
            }
            return $0.modelId < $1.modelId
        }
    }
}
