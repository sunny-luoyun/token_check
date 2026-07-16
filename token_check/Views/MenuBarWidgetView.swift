import SwiftUI
import Charts

struct MenuBarWidgetView: View {
    @ObservedObject var model: TokenViewModel

    private var total7Day: Int {
        model.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

    @AppStorage("widgetStat1") private var stat1 = "inputTokens"
    @AppStorage("widgetStat2") private var stat2 = "cacheReadTokens"
    @AppStorage("widgetStat3") private var stat3 = "outputTokens"
    @AppStorage("widgetStat4") private var stat4 = "sessionCount"
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
                        Text("余额 $\(balance)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                    }
                }
            }

            HStack(spacing: 0) {
                statItem(statLabel(stat1), statValue(stat1, model: model, usage: usage), statColor(stat1))
                Spacer()
                statItem(statLabel(stat2), statValue(stat2, model: model, usage: usage), statColor(stat2))
                Spacer()
                statItem(statLabel(stat3), statValue(stat3, model: model, usage: usage), statColor(stat3))
                Spacer()
                statItem(statLabel(stat4), statValue(stat4, model: model, usage: usage), statColor(stat4))
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
        String(format: "$%.2f", c)
    }

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

    private func statValue(_ key: String, model: TokenViewModel, usage: TodayUsage) -> String {
        switch key {
        case "inputTokens":    return formatTokens(model.adjustedInput)
        case "outputTokens":   return formatTokens(model.adjustedOutput)
        case "reasoningTokens": return formatTokens(model.adjustedReasoning)
        case "cacheReadTokens": return formatTokens(model.adjustedCacheRead)
        case "cacheWriteTokens": return formatTokens(model.adjustedCacheWrite)
        case "totalTokens":    return formatTokens(model.adjustedTotal)
        case "todayCost":      return formatCost(usage.todayCost)
        case "sessionCount":   return "\(usage.sessionCount)"
        case "messageCount":   return "\(usage.messageCount)"
        case "projectCount":   return "\(usage.projectCount)"
        case "additions":      return formatTokens(usage.additions)
        case "deletions":      return formatTokens(usage.deletions)
        case "files":          return "\(usage.files)"
        case "netAdditions":   return formatTokens(usage.additions - usage.deletions)
        default:               return "—"
        }
    }

    private func statLabel(_ key: String) -> String {
        switch key {
        case "inputTokens":    return "输入"
        case "outputTokens":   return "输出"
        case "reasoningTokens": return "推理"
        case "cacheReadTokens": return "缓存"
        case "cacheWriteTokens": return "缓存写入"
        case "totalTokens":    return "总计"
        case "todayCost":      return "费用"
        case "sessionCount":   return "会话"
        case "messageCount":   return "消息"
        case "projectCount":   return "项目"
        case "additions":      return "新增"
        case "deletions":      return "删除"
        case "files":          return "文件"
        case "netAdditions":   return "净增"
        default:               return key
        }
    }

    private func statColor(_ key: String) -> Color {
        switch key {
        case "inputTokens":    return .blue
        case "outputTokens":   return .green
        case "reasoningTokens": return .purple
        case "cacheReadTokens": return .teal
        case "cacheWriteTokens": return .cyan
        case "totalTokens":    return .indigo
        case "todayCost":      return .red
        case "sessionCount":   return .orange
        case "messageCount":   return .yellow
        case "projectCount":   return .purple
        case "additions":      return .green
        case "deletions":      return .red
        case "files":          return .blue
        case "netAdditions":   return .teal
        default:               return .gray
        }
    }
}
