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
