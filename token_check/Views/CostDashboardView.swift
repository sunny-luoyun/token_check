import SwiftUI

struct CostDashboardView: View {
    @StateObject private var viewModel = CostViewModel()

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
            } else if let summary = viewModel.summary {
                timeFilterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                summaryCards(summary: summary)
                    .padding(.horizontal)

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
        HStack(spacing: 12) {
            StatCardView(
                title: "总费用",
                value: formatCost(summary.totalCost),
                subtitle: "\(summary.sessionCount) 个会话",
                icon: "yensign.circle.fill",
                color: .red
            )
            StatCardView(
                title: "缓存未命中",
                value: formatTokens(summary.totalMissTokens),
                subtitle: formatCost(summary.missCost),
                icon: "arrowtriangle.down.circle.fill",
                color: .orange
            )
            StatCardView(
                title: "缓存命中",
                value: formatTokens(summary.totalHitTokens),
                subtitle: formatCost(summary.hitCost),
                icon: "memorychip.fill",
                color: .green
            )
            StatCardView(
                title: "输出",
                value: formatTokens(summary.totalOutputTokens),
                subtitle: formatCost(summary.outputCost),
                icon: "arrowtriangle.up.circle.fill",
                color: .blue
            )
        }
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
            Text("缓存未命中 ¥1/百万token")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("缓存命中 ¥0.02/百万token")
                .font(.caption2)
                .foregroundStyle(.green)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("输出 ¥2/百万token")
                .font(.caption2)
                .foregroundStyle(.blue)
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
