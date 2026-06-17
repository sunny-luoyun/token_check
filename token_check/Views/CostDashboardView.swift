import SwiftUI

struct CostDashboardView: View {
    @StateObject private var viewModel = CostViewModel()
    @AppStorage(ModelPricingStore.storageKey, store: ModelPricingStore.sharedDefaults) private var pricingRulesData = Data()

    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loadingSkeleton
            } else if let error = viewModel.error {
                errorView(error)
            } else if let summary = viewModel.summary {
                timeFilterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                summaryCards(summary: summary)
                    .padding(.horizontal)
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

                Divider()
                    .padding(.vertical, 8)

                costTable
                    .padding(.horizontal)

                costFooter(summary: summary)
                    .padding()
            }
        }
        .navigationTitle("费用")
        .toolbar {
            ToolbarItem {
                Button(action: { viewModel.applyFilter() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
            ToolbarItem {
                Toggle(isOn: $viewModel.showRollback) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(viewModel.showRollback ? .red : .secondary)
                }
                .toggleStyle(.button)
                .help("显示回滚消耗")
                .disabled(!viewModel.hasRollback)
                .onChange(of: viewModel.showRollback) { _, _ in
                    viewModel.applyFilter()
                }
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
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: theme.radiusMedium)
                        .fill(.quaternary.opacity(0.5))
                        .frame(height: 140)
                        .shimmering()
                }
            }
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

    private var timeFilterBar: some View {
        HStack {
            Spacer()
            TimeFilterView(
                years: viewModel.availableYears,
                months: viewModel.availableMonths,
                days: viewModel.availableDays,
                selectedYear: $viewModel.selectedYear,
                selectedMonth: $viewModel.selectedMonth,
                selectedDay: $viewModel.selectedDay,
                onChange: { viewModel.applyFilter() }
            )
            Spacer()
        }
    }

    private func summaryCards(summary: CostSummary) -> some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 150), spacing: 12)
        ], spacing: 12) {
            StatCardView(
                title: "总费用",
                value: formatCost(summary.totalCost),
                subtitle: "\(summary.sessionCount) 个会话",
                icon: "yensign.circle.fill",
                color: .red
            )
            .transition(.scale.combined(with: .opacity))

            StatCardView(
                title: "输入（未命中）",
                value: formatTokens(summary.totalMissTokens),
                subtitle: formatCost(summary.missCost),
                icon: "arrowtriangle.down.circle.fill",
                color: .orange
            )
            .transition(.scale.combined(with: .opacity))

            StatCardView(
                title: "缓存命中",
                value: formatTokens(summary.totalHitTokens),
                subtitle: formatCost(summary.hitCost),
                icon: "memorychip.fill",
                color: .green
            )
            .transition(.scale.combined(with: .opacity))

            StatCardView(
                title: "输出",
                value: formatTokens(summary.totalOutputTokens),
                subtitle: formatCost(summary.outputCost),
                icon: "arrowtriangle.up.circle.fill",
                color: .blue
            )
            .transition(.scale.combined(with: .opacity))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: summary.totalCost)
    }

    private var costTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按 Model 分解")
                .font(.headline)

            CostBreakdownTable(breakdown: viewModel.modelBreakdown)
                .frame(minHeight: 100)
        }
    }

    private func costFooter(summary: CostSummary) -> some View {
        HStack {
            Text("费用说明: ")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.pricingDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("总计 \(formatCost(summary.totalCost))")
                .font(.caption.monospaced().bold())
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            String(format: "%.2fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.1fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }

    private func formatCost(_ c: Double) -> String {
        String(format: "¥%.4f", c)
    }
}
