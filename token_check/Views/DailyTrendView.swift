import SwiftUI
import Charts

struct DailyTrendView: View {
    @StateObject private var viewModel = DailyTrendViewModel()

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
        }
        .navigationTitle("趋势")
        .onAppear {
            viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: SharedStorage.pricingRulesUpdated)) { _ in
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

    // MARK: - Header

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
            .onChange(of: viewModel.timeMode) { _ in
                viewModel.applyFilter()
            }

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

    // MARK: - Chart

    @State private var chartAnimated = false

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

    private var chartSection: some View {
        TrendChartView(
            viewModel: viewModel,
            modelColors: modelColors,
            chartAnimated: $chartAnimated
        )
    }

    // MARK: - Model Chips

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

    // MARK: - Helpers

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            String(format: "%.1fB", Double(n) / 1_000_000_000)
        } else if n >= 1_000_000 {
            String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.0fK", Double(n) / 1_000)
        } else {
            "\(n)"
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
            return viewModel.cost(for: item, metric: viewModel.selectedMetric)
        }
        switch viewModel.selectedMetric {
        case .total: return Double(item.totalTokens)
        case .input: return Double(item.inputTokens)
        case .cacheHit: return Double(item.cacheReadTokens)
        case .output: return Double(item.outputTokens)
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
        if n >= 1_000_000_000 { String(format: "%.1fB", Double(n) / 1_000_000_000) }
        else if n >= 1_000_000 { String(format: "%.1fM", Double(n) / 1_000_000) }
        else if n >= 1_000 { String(format: "%.0fK", Double(n) / 1_000) }
        else { "\(n)" }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { String(format: "$%.4f", value) }
        else if value < 1 { String(format: "$%.2f", value) }
        else { String(format: "$%.1f", value) }
    }
}
