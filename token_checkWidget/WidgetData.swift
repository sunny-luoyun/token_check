import Foundation

struct WidgetDayTokenData: Decodable {
    let id: String
    let date: Date
    let totalTokens: Int
    let dailyCost: Double

    enum CodingKeys: String, CodingKey {
        case id, date, totalTokens, dailyCost
    }

    init(id: String, date: Date, totalTokens: Int, dailyCost: Double = 0) {
        self.id = id
        self.date = date
        self.totalTokens = totalTokens
        self.dailyCost = dailyCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        dailyCost = try container.decodeIfPresent(Double.self, forKey: .dailyCost) ?? 0
    }
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

struct WidgetYearlyHeatmapData: Decodable {
    let year: Int
    let totalTokens: Int
    let avgDailyTokens: Int
    let days: [WidgetDayTokenData]
    let firstWeekday: Int
    let totalDays: Int
}
