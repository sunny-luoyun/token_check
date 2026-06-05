import SwiftUI
import Charts

struct DailyTrendView: View {
    @StateObject private var viewModel = DailyTrendViewModel()

    private let modelColors: [Color] = [
        .blue, .green, .orange, .purple, .red, .teal, .pink, .indigo,
        .mint, .yellow, .brown, .cyan
    ]

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                Spacer()
                ProgressView("正在加载…")
                Spacer()
            } else if let error = viewModel.error {
                Spacer()
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
                Spacer()
            } else {
                timeFilterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                if viewModel.isMonthlyMode {
                    monthFilterBar
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                chartSection
                    .padding(.horizontal)

                modelLegend
                    .padding(.horizontal)
                    .padding(.top, 8)
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
    }

    // MARK: - Time Filter

    private var timeFilterBar: some View {
        HStack {
            Spacer()
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
            Spacer()
        }
    }

    private var monthFilterBar: some View {
        HStack {
            Spacer()
            TimeFilterView(
                years: viewModel.availableYears,
                months: viewModel.availableMonths,
                selectedYear: $viewModel.selectedYear,
                selectedMonth: $viewModel.selectedMonth,
                onChange: { viewModel.applyFilter() }
            )
            Spacer()
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日 Token 趋势")
                .font(.headline)

            let models = Array(Set(viewModel.filteredData.map(\.displayName))).sorted()
            let colorMap = Dictionary(uniqueKeysWithValues: models.enumerated().map { (i, model) in
                (model, modelColors[i % modelColors.count])
            })

            Chart(viewModel.filteredData) { item in
                LineMark(
                    x: .value("日期", item.date),
                    y: .value("Tokens", item.totalTokens)
                )
                .foregroundStyle(by: .value("Model", item.displayName))

                AreaMark(
                    x: .value("日期", item.date),
                    y: .value("Tokens", item.totalTokens)
                )
                .foregroundStyle(by: .value("Model", item.displayName))
                .opacity(0.1)
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
                    AxisValueLabel { Text(formatTokens(value.as(Int.self) ?? 0)) }
                }
            }
            .frame(height: 300)
        }
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
}
