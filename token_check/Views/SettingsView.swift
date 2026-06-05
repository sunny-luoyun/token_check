import SwiftUI

struct SettingsView: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("refreshMinutes") private var refreshMinutes = 5
    @State private var pricingRules: [ModelPricingRule] = []
    @State private var pricingError: String?
    @State private var isLoadingPricing = false

    var body: some View {
        Form {
            Section("外观") {
                Toggle("显示 Dock 图标", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, newValue in
                        NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                        if newValue {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
            }

            Section("刷新") {
                Picker("自动刷新间隔", selection: $refreshMinutes) {
                    Text("1 分钟").tag(1)
                    Text("2 分钟").tag(2)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
                Text("修改后立即生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("模型价格") {
                if isLoadingPricing {
                    ProgressView("正在加载模型…")
                } else if let pricingError {
                    Text(pricingError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if pricingRules.isEmpty {
                    Text("还没有读取到模型记录，先使用一下模型再回来设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("当前按模型 ID + variant 分别配置。价格单位：元 / 百万 token。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复全部默认价格", action: resetAllPricing)
                            .buttonStyle(.borderless)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("模型")
                                .font(.caption.bold())
                            Text("启用")
                                .font(.caption.bold())
                            Text("输入（无缓存）")
                                .font(.caption.bold())
                            Text("输入（有缓存）")
                                .font(.caption.bold())
                            Text("输出")
                                .font(.caption.bold())
                            Text("")
                        }

                        ForEach($pricingRules) { $rule in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.displayName)
                                        .font(.caption)
                                    if !rule.usesDefaultPricing {
                                        Text("已自定义")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                        }
                                }

                                Toggle("", isOn: $rule.isEnabled)
                                    .labelsHidden()

                                TextField(
                                    "输入（无缓存）",
                                    value: $rule.inputMissPricePerMillion,
                                    format: .number.precision(.fractionLength(0...4))
                                )
                                .textFieldStyle(.roundedBorder)
                                .disabled(!rule.isEnabled)

                                TextField(
                                    "输入（有缓存）",
                                    value: $rule.cacheHitPricePerMillion,
                                    format: .number.precision(.fractionLength(0...4))
                                )
                                .textFieldStyle(.roundedBorder)
                                .disabled(!rule.isEnabled)

                                TextField(
                                    "输出",
                                    value: $rule.outputPricePerMillion,
                                    format: .number.precision(.fractionLength(0...4))
                                )
                                .textFieldStyle(.roundedBorder)
                                .disabled(!rule.isEnabled)

                                Button("默认") {
                                    resetPricing(for: rule.pricingKey)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Section("桌面小组件") {
                HStack {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .foregroundStyle(.blue)
                    Text("菜单栏点击「移动」可拖拽，再点「固定」锁定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: loadPricingRules)
        .onChange(of: pricingRules) {
            savePricingRules()
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 520)
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
