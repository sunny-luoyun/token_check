import SwiftUI
import Charts

struct ModelBreakdownChart: View {
    let modelUsage: [ModelUsage]

    @State private var isAnimated = false

    var body: some View {
        VStack {
            Chart {
                ForEach(modelUsage) { item in
                    BarMark(
                        x: .value("Tokens", item.inputTokens),
                        y: .value("Model", item.displayName)
                    )
                    .foregroundStyle(by: .value("Type", "Input"))
                    .position(by: .value("Type", "Input"))
                    .opacity(isAnimated ? 1 : 0)

                    BarMark(
                        x: .value("Tokens", item.outputTokens),
                        y: .value("Model", item.displayName)
                    )
                    .foregroundStyle(by: .value("Type", "Output"))
                    .position(by: .value("Type", "Output"))
                    .opacity(isAnimated ? 1 : 0)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let n = value.as(Double.self) {
                            Text(compactTokenLabel(n))
                        }
                    }
                }
            }
            .chartXAxisLabel("Tokens")
            .chartForegroundStyleScale([
                "Input": Color.blue,
                "Output": Color.green
            ])
            .frame(height: CGFloat(max(modelUsage.count * 40, 120)))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).delay(0.1)) {
                isAnimated = true
            }
        }
    }
}

struct DailyTrendChart: View {
    let dailyUsage: [DailyUsage]

    @State private var isAnimated = false

    var body: some View {
        VStack {
            Chart {
                ForEach(dailyUsage) { item in
                    AreaMark(
                        x: .value("Date", item.date),
                        y: .value("Tokens", item.totalTokens)
                    )
                    .foregroundStyle(Gradient(colors: [Color.blue.opacity(0.3), .clear]))
                    .opacity(isAnimated ? 1 : 0)

                    LineMark(
                        x: .value("Date", item.date),
                        y: .value("Tokens", item.totalTokens)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .opacity(isAnimated ? 1 : 0)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.day().month())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let n = value.as(Double.self) {
                            Text(compactTokenLabel(n))
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).delay(0.15)) {
                isAnimated = true
            }
        }
        .onChange(of: dailyUsage.count) { _, _ in
            isAnimated = false
            withAnimation(.easeInOut(duration: 0.6).delay(0.1)) {
                isAnimated = true
            }
        }
    }
}

struct ModelBreakdownStackedChart: View {
    let modelUsage: [ModelCostBreakdown]

    @Environment(\.appTheme) var theme
    @State private var isAnimated = false

    var body: some View {
        Chart {
            ForEach(modelUsage) { item in
                BarMark(
                    x: .value("Tokens", item.cacheMissTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Input"))
                .opacity(isAnimated ? 1 : 0)

                BarMark(
                    x: .value("Tokens", item.cacheHitTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Cache"))
                .opacity(isAnimated ? 1 : 0)

                BarMark(
                    x: .value("Tokens", item.outputTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Output"))
                .opacity(isAnimated ? 1 : 0)

                BarMark(
                    x: .value("Tokens", item.reasoningTokens),
                    y: .value("Model", item.displayName)
                )
                .foregroundStyle(by: .value("Type", "Reasoning"))
                .opacity(isAnimated ? 1 : 0)
            }
        }
        .chartForegroundStyleScale([
            "Input": theme.inputMiss,
            "Cache": theme.cacheHit,
            "Output": theme.output,
            "Reasoning": theme.reasoning
        ])
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let n = value.as(Double.self) {
                        Text(compactTokenLabel(n))
                    }
                }
            }
        }
        .chartXAxisLabel("Tokens")
        .frame(height: CGFloat(max(modelUsage.count * 40, 120)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).delay(0.1)) {
                isAnimated = true
            }
        }
        .onChange(of: modelUsage.count) { _, _ in
            isAnimated = false
            withAnimation(.easeInOut(duration: 0.6).delay(0.1)) {
                isAnimated = true
            }
        }
    }
}

/// 图表刻度紧凑计数格式：k / M / B（替代科学计数法）
private func compactTokenLabel(_ n: Double) -> String {
    let value = abs(n)
    if value >= 1_000_000_000 {
        return String(format: "%.1fB", n / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1fM", n / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.0fK", n / 1_000)
    }
    return String(format: "%.0f", n)
}
