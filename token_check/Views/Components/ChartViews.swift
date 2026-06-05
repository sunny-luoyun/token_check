import SwiftUI
import Charts

struct ModelBreakdownChart: View {
    let modelUsage: [ModelUsage]

    var body: some View {
        Chart(modelUsage) { item in
            BarMark(
                x: .value("Tokens", item.inputTokens),
                y: .value("Model", item.displayName)
            )
            .foregroundStyle(by: .value("Type", "Input"))
            .position(by: .value("Type", "Input"))

            BarMark(
                x: .value("Tokens", item.outputTokens),
                y: .value("Model", item.displayName)
            )
            .foregroundStyle(by: .value("Type", "Output"))
            .position(by: .value("Type", "Output"))
        }
        .chartXAxisLabel("Tokens")
        .chartForegroundStyleScale([
            "Input": Color.blue,
            "Output": Color.green
        ])
        .frame(height: CGFloat(max(modelUsage.count * 40, 120)))
    }
}

struct DailyTrendChart: View {
    let dailyUsage: [DailyUsage]

    var body: some View {
        Chart(dailyUsage) { item in
            AreaMark(
                x: .value("Date", item.date),
                y: .value("Tokens", item.totalTokens)
            )
            .foregroundStyle(Gradient(colors: [Color.blue.opacity(0.3), .clear]))

            LineMark(
                x: .value("Date", item.date),
                y: .value("Tokens", item.totalTokens)
            )
            .foregroundStyle(.blue)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.day().month())
            }
        }
        .frame(height: 200)
    }
}
