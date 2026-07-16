import AppIntents
import WidgetKit

enum WidgetStatOption: String, AppEnum {
    case inputTokens
    case outputTokens
    case reasoningTokens
    case cacheReadTokens
    case cacheWriteTokens
    case totalTokens
    case todayCost
    case sessionCount
    case messageCount
    case projectCount
    case additions
    case deletions
    case files
    case netAdditions

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "统计指标")

    static let caseDisplayRepresentations: [WidgetStatOption: DisplayRepresentation] = [
        .inputTokens: "输入",
        .outputTokens: "输出",
        .reasoningTokens: "推理",
        .cacheReadTokens: "缓存",
        .cacheWriteTokens: "缓存写入",
        .totalTokens: "总计",
        .todayCost: "费用",
        .sessionCount: "会话",
        .messageCount: "消息",
        .projectCount: "项目",
        .additions: "新增",
        .deletions: "删除",
        .files: "文件",
        .netAdditions: "净增",
    ]
}

enum WidgetChartRange: String, AppEnum {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case todayHourly = "1h"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "图表范围")

    static let caseDisplayRepresentations: [WidgetChartRange: DisplayRepresentation] = [
        .sevenDays: "近7天",
        .thirtyDays: "近30天",
        .todayHourly: "当天分时",
    ]
}

struct LargeWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "大组件设置"
    static var description: IntentDescription = IntentDescription("配置顶部指标和图表范围")

    @Parameter(title: "指标1", default: WidgetStatOption.inputTokens)
    var stat1: WidgetStatOption

    @Parameter(title: "指标2", default: WidgetStatOption.cacheReadTokens)
    var stat2: WidgetStatOption

    @Parameter(title: "指标3", default: WidgetStatOption.outputTokens)
    var stat3: WidgetStatOption

    @Parameter(title: "指标4", default: WidgetStatOption.sessionCount)
    var stat4: WidgetStatOption

    @Parameter(title: "图表范围", default: WidgetChartRange.sevenDays)
    var chartRange: WidgetChartRange
}
