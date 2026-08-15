import Foundation

// MARK: - 数据源

/// 统计页面通用数据源（费用/趋势/会话/统计页共用）
enum StatsDataSource: String, CaseIterable {
    case opencode = "opencode"
    case dsh = "DSH"
    /// opencode + DSH 合并统计
    case all = "总"

    var detailText: String {
        switch self {
        case .opencode: return "opencode 数据库"
        case .dsh: return "DeepSeek Harness"
        case .all: return "opencode + DSH 合并统计"
        }
    }
}

// MARK: - ~/.dsh 磁盘文件 JSON 镜像

/// `~/.dsh/storages/session_projcache.json`
/// 每个会话一条投影缓存记录（{ver, seq, val}），记录按会话永久累积，无淘汰。
struct DshProjCache: Decodable {
    struct Tables: Decodable {
        let sessions: [String: DshSessionEntry]
    }
    let tables: Tables
}

struct DshSessionEntry: Decodable {
    struct Identity: Decodable {
        /// 会话创建时间（毫秒时间戳）
        let createdAt: Int64
        let cwd: String
    }

    struct Rows: Decodable {
        let tokenUsage: DshRow<DshTokenUsage>?
        let sessionStats: DshRow<DshSessionStats>?
        /// val 可能为 null（会话尚未生成标题）
        let title: DshRow<String?>?
        let contextPressure: DshRow<DshContextPressure>?
        let contextBreakdown: DshRow<DshContextBreakdown>?
    }

    let identity: Identity
    let rows: Rows
}

/// 投影缓存行只取 `val` 字段（`ver`/`seq` 为投影内部版本号）
struct DshRow<T: Decodable>: Decodable {
    let val: T
}

struct DshTokenUsage: Decodable {
    struct Totals: Decodable {
        let uncachedInputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
    }
    let totals: Totals
}

struct DshSessionStats: Decodable {
    let turns: Int?
    let steps: Int?
    let llmMs: Int64?
    let toolMs: Int64?
    let ttftMs: Int64?
    let decodeMs: Int64?
    let decodeTokens: Int?
}

struct DshContextPressure: Decodable {
    let surfaceTokens: Int?
    let contextWindow: Int?
    let pressureTokens: Int?
}

struct DshContextBreakdown: Decodable {
    let systemTokens: Int?
    let toolsTokens: Int?
    let messageTokens: Int?
}

/// `~/.dsh/storages/workspace.json`：工作区 → 会话索引
struct DshWorkspaceStore: Decodable {
    struct Tables: Decodable {
        let workspaces: [String: DshWorkspace]
    }
    let tables: Tables
}

struct DshWorkspace: Decodable {
    let path: String
    let title: String?
    let sessionIds: [String]?
}

// MARK: - 领域模型

/// 单个 DSH 会话的统计（L1 来自投影缓存，费用为估算值）
struct DshSessionStat: Identifiable {
    let id: String
    let title: String?
    let createdAt: Date
    let cwd: String
    let projectName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let turns: Int
    let steps: Int
    let llmMs: Int64
    let toolMs: Int64
    let ttftMs: Int64
    let decodeMs: Int64
    let decodeTokens: Int
    let surfaceTokens: Int?
    let contextWindow: Int?
    /// 按模型价格规则估算的费用（DSH 本身不记录真实费用）
    let estimatedCost: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }
}

/// 按工作区（cwd）聚合的项目统计
struct DshProjectStat: Identifiable {
    let id: String
    let name: String
    let path: String
    let sessions: Int
    let totalTokens: Int
    let estimatedCost: Double
    let lastActiveAt: Date?
}

/// 一次读取的完整快照
struct DshSnapshot {
    let sessions: [DshSessionStat]
    let projects: [DshProjectStat]
    /// 默认模型（来自 ~/.dsh/settings.yaml 的 agent-default-model）
    let defaultModel: DshDefaultModel?
    let readAt: Date

    var sessionCount: Int { sessions.count }
    var projectCount: Int { projects.count }
    var totalInput: Int { sessions.reduce(0) { $0 + $1.inputTokens } }
    var totalOutput: Int { sessions.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheRead: Int { sessions.reduce(0) { $0 + $1.cacheReadTokens } }
    var totalCacheWrite: Int { sessions.reduce(0) { $0 + $1.cacheWriteTokens } }
    var totalTokens: Int { sessions.reduce(0) { $0 + $1.totalTokens } }
    var totalEstimatedCost: Double { sessions.reduce(0) { $0 + $1.estimatedCost } }
    var totalSteps: Int { sessions.reduce(0) { $0 + $1.steps } }
    var totalLlmSeconds: Double { Double(sessions.reduce(Int64(0)) { $0 + $1.llmMs }) / 1000 }
}

/// DSH 默认模型路由（settings.yaml `agent-default-model` 段）
struct DshDefaultModel {
    let providerID: String
    let modelId: String
    let variant: String

    var displayName: String {
        if modelId.isEmpty || modelId == "unknown" {
            return "未知模型"
        }
        if providerID == "opencode" || providerID == "opencode-go" || providerID.isEmpty {
            return modelId
        }
        return "[\(providerID)] \(modelId)"
    }
}

// MARK: - L2 事件级数据

/// 一次 LLM 调用的记账（来自 JSONL 中 assistant/message 事件的 data.usage + message.source）
struct DshUsageEvent {
    let sessionID: String
    let seq: Int
    let time: Date
    let turn: Int
    let step: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let providerID: String
    let modelId: String

    var modelKey: String { "\(providerID)/\(modelId)/default" }
}

/// DSH 会话日志头（JSONL 首行）
struct DshLogHeader {
    let id: String
    let createdAt: Date
    let cwd: String
    let agentPreset: String?
    let parentSession: String?
    let delegationDepth: Int?
}

/// L2 数据完整度
enum DshDetailLevel {
    /// 事件级（已解析 JSONL，全部指标可用）
    case full
    /// 仅投影缓存（zstd 不可用或日志缺失，回退 L1：无每日分解、模型按默认路由）
    case totalsOnly
    /// 未检测到 DSH 数据
    case missing
}

/// 时间过滤（对齐 DatabaseService 的 year/month/day 或 from/to 双模式）
struct DshTimeFilter {
    var from: Date?
    var to: Date?
    var year: String?
    var month: String?
    var day: String?

    /// 判断事件时间是否在过滤范围内（from/to 含 to 当天；year/month/day 为本地时区）
    func includes(_ date: Date) -> Bool {
        let cal = Calendar.current
        if let from, let to {
            let start = cal.startOfDay(for: from)
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to)) ?? to
            return date >= start && date < end
        }
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        if let year, String(comps.year ?? 0) != year { return false }
        if let month, String(format: "%02d", comps.month ?? 0) != month { return false }
        if let day, String(format: "%02d", comps.day ?? 0) != day { return false }
        return true
    }
}
