import Foundation

struct WidgetDayTokenData: Codable {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(dailyCost, forKey: .dailyCost)
    }
}

struct WidgetHourlyData: Codable {
    let hour: Int
    let totalTokens: Int
    let cost: Double
}

struct WidgetTodayUsage: Codable {
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
    let hourlyTokens: [WidgetHourlyData]
    let todayCost: Double
    let subscriptionRemaining: Double?
    let subscriptionBudget: Double?
    let subscriptionUsed: Double?
    let subscriptionEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case totalTokens, inputTokens, outputTokens, cacheReadTokens
        case reasoningTokens, cacheWriteTokens
        case sessionCount, messageCount, projectCount
        case additions, deletions, files
        case dailyTokens, hourlyTokens, todayCost
        case subscriptionRemaining, subscriptionBudget, subscriptionUsed, subscriptionEnabled
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
        hourlyTokens = try container.decodeIfPresent([WidgetHourlyData].self, forKey: .hourlyTokens) ?? []
        todayCost = try container.decode(Double.self, forKey: .todayCost)
        subscriptionRemaining = try container.decodeIfPresent(Double.self, forKey: .subscriptionRemaining)
        subscriptionBudget = try container.decodeIfPresent(Double.self, forKey: .subscriptionBudget)
        subscriptionUsed = try container.decodeIfPresent(Double.self, forKey: .subscriptionUsed)
        subscriptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .subscriptionEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(reasoningTokens, forKey: .reasoningTokens)
        try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try container.encode(sessionCount, forKey: .sessionCount)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encode(projectCount, forKey: .projectCount)
        try container.encode(additions, forKey: .additions)
        try container.encode(deletions, forKey: .deletions)
        try container.encode(files, forKey: .files)
        try container.encode(dailyTokens, forKey: .dailyTokens)
        try container.encode(hourlyTokens, forKey: .hourlyTokens)
        try container.encode(todayCost, forKey: .todayCost)
        try container.encodeIfPresent(subscriptionRemaining, forKey: .subscriptionRemaining)
        try container.encodeIfPresent(subscriptionBudget, forKey: .subscriptionBudget)
        try container.encodeIfPresent(subscriptionUsed, forKey: .subscriptionUsed)
        try container.encode(subscriptionEnabled, forKey: .subscriptionEnabled)
    }
}

struct WidgetMonthlyHeatmapData: Codable {
    let year: Int
    let month: Int
    let totalTokens: Int
    let avgDailyTokens: Int
    let days: [WidgetDayTokenData]
    let firstWeekday: Int
}

struct WidgetYearlyHeatmapData: Codable {
    let year: Int
    let totalTokens: Int
    let avgDailyTokens: Int
    let days: [WidgetDayTokenData]
    let firstWeekday: Int
    let totalDays: Int
}

struct CombinedWidgetData: Codable {
    let todayUsage: WidgetTodayUsage?
    let monthlyHeatmap: WidgetMonthlyHeatmapData?
    let yearlyHeatmap: WidgetYearlyHeatmapData?
}
