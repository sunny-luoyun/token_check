import SwiftUI
import Charts

struct MenuBarWidgetView: View {
    @ObservedObject var model: TokenViewModel

    private var total7Day: Int {
        model.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

    @State private var chartAnimated = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(height: 180)
            } else if let error = model.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(height: 180)
                .transition(.opacity)
            } else if let usage = model.usage {
                todaySection(usage)
                Divider()
                    .padding(.vertical, 8)
                chartSection
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            model.refresh()
        }
    }

    private func todaySection(_ usage: TodayUsage) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.blue)
                HStack(spacing: 4) {
                    Text("今日用量")
                        .font(.headline)
                    if model.hasRollback {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text("+\(formatTokens(model.rollbackTotal))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatTokens(model.adjustedTotal))
                        .font(.title2.monospaced().bold())
                    Text(formatCost(usage.todayCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if model.deepseekLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else if let balance = model.deepseekBalance {
                        Text("余额 ¥\(balance)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                    }
                }
            }

            HStack(spacing: 0) {
                statItem("输入", formatTokens(model.adjustedInput), .blue)
                Spacer()
                statItem("缓存", formatTokens(model.adjustedCacheRead), .purple)
                Spacer()
                statItem("输出", formatTokens(model.adjustedOutput), .green)
                Spacer()
                statItem("会话", "\(usage.sessionCount)", .orange)
            }
            .font(.caption)
        }
    }

    private func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        if let usage = model.usage, !usage.dailyTokens.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("近 7 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("共 \(formatTokens(total7Day))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                let maxVal = usage.dailyTokens.map(\.totalTokens).max() ?? 1
                Chart(usage.dailyTokens) { item in
                    BarMark(
                        x: .value("日期", item.date, unit: .day),
                        y: .value("Token 量", chartAnimated ? item.totalTokens : 0)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...(maxVal * 12 / 10))
                .frame(height: 80)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: chartAnimated)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
                        chartAnimated = true
                    }
                }
            }
        }
    }

    private func formatCost(_ c: Double) -> String {
        String(format: "¥%.2f", c)
    }

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
