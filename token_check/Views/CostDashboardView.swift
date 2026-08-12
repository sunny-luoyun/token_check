import SwiftUI

struct CostDashboardView: View {
    @StateObject private var viewModel = CostViewModel()

    @Environment(\.appTheme) var theme

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
        if n >= 1_000_000_000 {
            String(format: "%.2fB", Double(n) / 1_000_000_000)
        } else if n >= 1_000_000 {
            String(format: "%.2fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.1fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }

    private func formatCost(_ c: Double) -> String {
        String(format: "$%.4f", c)
    }
}
