import Foundation

struct WidgetDayTokenData: Decodable {
    let id: String
    let date: Date
    let totalTokens: Int
}

struct WidgetTodayUsage: Decodable {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let sessionCount: Int
    let dailyTokens: [WidgetDayTokenData]
    let todayCost: Double
}

struct WidgetMonthlyHeatmapData: Decodable {
    let year: Int
    let month: Int
    let totalTokens: Int
    let avgDailyTokens: Int
    let days: [WidgetDayTokenData]
    let firstWeekday: Int
}
