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
    let reasoningTokens: Int
    let cacheWriteTokens: Int
    let sessionCount: Int
    let messageCount: Int
    let projectCount: Int
    let additions: Int
    let deletions: Int
    let files: Int
    let dailyTokens: [WidgetDayTokenData]
    let todayCost: Double

    enum CodingKeys: String, CodingKey {
        case totalTokens, inputTokens, outputTokens, cacheReadTokens
        case reasoningTokens, cacheWriteTokens
        case sessionCount, messageCount, projectCount
        case additions, deletions, files
        case dailyTokens, todayCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        projectCount = try container.decodeIfPresent(Int.self, forKey: .projectCount) ?? 0
        additions = try container.decodeIfPresent(Int.self, forKey: .additions) ?? 0
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        files = try container.decodeIfPresent(Int.self, forKey: .files) ?? 0
        dailyTokens = try container.decode([WidgetDayTokenData].self, forKey: .dailyTokens)
        todayCost = try container.decode(Double.self, forKey: .todayCost)
    }
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

struct CombinedWidgetData: Decodable {
    let todayUsage: WidgetTodayUsage?
    let monthlyHeatmap: WidgetMonthlyHeatmapData?
    let yearlyHeatmap: WidgetYearlyHeatmapData?
}
