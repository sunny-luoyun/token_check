import SwiftUI
import Charts

struct DailyTrendView: View {
    @StateObject private var viewModel = DailyTrendViewModel()
    @AppStorage(ModelPricingStore.storageKey, store: ModelPricingStore.sharedDefaults) private var pricingRulesData = Data()

    @Environment(\.appTheme) var theme

    private let modelColors: [Color] = [
        .blue, .green, .orange, .purple, .red, .teal, .pink, .indigo,
        .mint, .yellow, .brown, .cyan
    ]

    var body: some View {
        VStack(spacing: 6) {
            if viewModel.isLoading {
                loadingSkeleton
            } else if let error = viewModel.error {
                errorView(error)
            } else {
                timeFilterBar
                    .padding(.horizontal)

                metricFilterBar
                    .padding(.horizontal)

                chartModeBar
                    .padding(.horizontal)

                chartSection
                    .padding(.horizontal)

                modelLegend
                    .padding(.horizontal)

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
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }
        }
        .navigationTitle("趋势")
        .toolbar {
            ToolbarItem {
                Button(action: {
                    viewModel.applyFilter()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
        .onAppear {
            viewModel.load()
        }
        .onChange(of: pricingRulesData) {
            viewModel.load()
        }
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 16) {
            Spacer()
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(.quaternary.opacity(0.5))
                .frame(height: 40)
                .shimmering()
                .padding(.horizontal)
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(.quaternary.opacity(0.5))
                .frame(height: 300)
                .shimmering()
                .padding(.horizontal)
            Spacer()
        }
    }

    private func errorView(_ error: String) -> some View {
        Spacer()
            .overlay {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重试", action: viewModel.load)
                        .buttonStyle(.bordered)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Time Filter

    private var timeFilterBar: some View {
        HStack {
            Picker("时间范围", selection: $viewModel.timeMode) {
                ForEach(DailyTrendViewModel.TimeMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360, alignment: .leading)
            .onChange(of: viewModel.timeMode) { _ in
                viewModel.applyFilter()
            }

            if viewModel.isMonthlyMode {
                TimeFilterView(
                    years: viewModel.availableYears,
                    months: viewModel.availableMonths,
                    days: viewModel.availableDays,
                    selectedYear: $viewModel.selectedYear,
                    selectedMonth: $viewModel.selectedMonth,
                    selectedDay: $viewModel.selectedDay,
                    onChange: { viewModel.applyFilter() }
                )
                .padding(.leading, 8)
            }

            Spacer()
        }
    }

    private var metricFilterBar: some View {
        HStack {
            Picker("输入输出", selection: $viewModel.selectedMetric) {
                ForEach(DailyTrendViewModel.MetricType.allCases, id: \.self) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 480, alignment: .leading)
            Spacer()
        }
    }

    // MARK: - Chart Mode

    private var chartModeBar: some View {
        HStack {
            Picker("统计指标", selection: $viewModel.chartMode) {
                ForEach(DailyTrendViewModel.ChartMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200, alignment: .leading)
            Spacer()
        }
    }

    // MARK: - Chart

    @State private var chartAnimated = false

    private var chartSection: some View {
        TrendChartView(
            viewModel: viewModel,
            modelColors: modelColors,
            chartAnimated: $chartAnimated
        )
    }

    // MARK: - Model Legend

    private var modelLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模型过滤")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
                            .background(isSelected ? color.opacity(0.12) : Color.gray.opacity(0.08))
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(isSelected ? color : Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Helpers

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.0fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 {
            String(format: "¥%.4f", value)
        } else if value < 1 {
            String(format: "¥%.2f", value)
        } else {
            String(format: "¥%.1f", value)
        }
    }
}

private struct TrendChartView: View {
    @ObservedObject var viewModel: DailyTrendViewModel
    let modelColors: [Color]
    @Binding var chartAnimated: Bool

    private var colorMap: [String: Color] {
        Dictionary(uniqueKeysWithValues: viewModel.availableModels.enumerated().map { (i, model) in
            (model, modelColors[i % modelColors.count])
        })
    }

    private var isCost: Bool {
        viewModel.chartMode == .cost
    }

    private func metricValue(for item: DailyModelUsage) -> Double {
        if isCost {
            let key = "\(item.modelId)/\(item.variant)"
            let pricing = viewModel.pricingLookup[key] ?? .defaults(modelId: item.modelId, variant: item.variant)
            switch viewModel.selectedMetric {
            case .total:
                return Double(item.inputTokens) / 1_000_000 * pricing.inputMissPricePerMillion
                    + Double(item.cacheReadTokens) / 1_000_000 * pricing.cacheHitPricePerMillion
                    + Double(item.outputTokens) / 1_000_000 * pricing.outputPricePerMillion
            case .input:
                return Double(item.inputTokens) / 1_000_000 * pricing.inputMissPricePerMillion
            case .cacheHit:
                return Double(item.cacheReadTokens) / 1_000_000 * pricing.cacheHitPricePerMillion
            case .output:
                return Double(item.outputTokens) / 1_000_000 * pricing.outputPricePerMillion
            }
        } else {
            switch viewModel.selectedMetric {
            case .total: return Double(item.totalTokens)
            case .input: return Double(item.inputTokens)
            case .cacheHit: return Double(item.cacheReadTokens)
            case .output: return Double(item.outputTokens)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(viewModel.filteredData) { item in
                    LineMark(
                        x: .value("日期", item.date),
                        y: .value(isCost ? "费用" : "Tokens", metricValue(for: item))
                    )
                    .foregroundStyle(by: .value("Model", item.displayName))
                    .opacity(chartAnimated ? 1 : 0)

                    PointMark(
                        x: .value("日期", item.date),
                        y: .value(isCost ? "费用" : "Tokens", metricValue(for: item))
                    )
                    .foregroundStyle(by: .value("Model", item.displayName))
                    .symbolSize(20)
                    .opacity(chartAnimated ? 1 : 0)
                }
            }
            .chartForegroundStyleScale { modelName in
                colorMap[modelName] ?? .gray
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.day().month())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if isCost {
                            Text(formatCost(value.as(Double.self) ?? 0))
                        } else {
                            Text(formatTokens(Int(value.as(Double.self) ?? 0)))
                        }
                    }
                }
            }
            .frame(height: 300)
            .onChange(of: viewModel.filteredData.count) { _, _ in
                chartAnimated = false
                withAnimation(.easeInOut(duration: 0.5).delay(0.1)) {
                    chartAnimated = true
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).delay(0.1)) {
                    chartAnimated = true
                }
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { String(format: "%.1fM", Double(n) / 1_000_000) }
        else if n >= 1_000 { String(format: "%.0fK", Double(n) / 1_000) }
        else { "\(n)" }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { String(format: "¥%.4f", value) }
        else if value < 1 { String(format: "¥%.2f", value) }
        else { String(format: "¥%.1f", value) }
    }
}
