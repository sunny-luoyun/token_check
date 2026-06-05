import SwiftUI
import Charts
import Combine

struct MenuBarWidgetView: View {
    @ObservedObject var model: TokenViewModel
    @AppStorage("refreshMinutes") private var refreshMinutes = 5
    @State private var timerCancellable: AnyCancellable?

    private var total7Day: Int {
        model.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

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
            startRefreshTimer()
        }
        .onDisappear {
            timerCancellable?.cancel()
        }
        .onChange(of: refreshMinutes) { _ in
            startRefreshTimer()
        }
    }

    private func todaySection(_ usage: TodayUsage) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.blue)
                Text("今日用量")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatTokens(usage.totalTokens))
                        .font(.title2.monospaced().bold())
                    Text(formatCost(usage.todayCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                statItem("输入", formatTokens(usage.inputTokens), .blue)
                Spacer()
                statItem("缓存", formatTokens(usage.cacheReadTokens), .purple)
                Spacer()
                statItem("输出", formatTokens(usage.outputTokens), .green)
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
                        y: .value("Token 量", item.totalTokens)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...(maxVal * 12 / 10))
                .frame(height: 80)
            }
        }
    }

    private func startRefreshTimer() {
        timerCancellable?.cancel()
        let interval = max(TimeInterval(refreshMinutes), 1) * 60
        timerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak model] _ in model?.refresh() }
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
