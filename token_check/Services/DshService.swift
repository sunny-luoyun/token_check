import Foundation
import OSLog

/// DeepSeek Harness (DSH) 数据服务 —— L1：只读投影缓存，无需解压 zstd JSONL。
///
/// 数据来源：
/// - `~/.dsh/storages/session_projcache.json`：每会话投影缓存（tokenUsage / sessionStats / title 等）
/// - `~/.dsh/storages/workspace.json`：工作区索引（path/title → sessionIds）
/// - `~/.dsh/settings.yaml`：默认模型路由（agent-default-model 段）
///
/// 限制（L1）：
/// - 无逐日/逐小时分解（需 L2 解析 JSONL 事件流）
/// - 每会话模型统一按默认模型估算费用（DSH 不记录真实费用）
final class DshService {
    static let shared = DshService()

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "dsh")

    /// 真实用户主目录（与 AppConstants 同思路：绕过沙盒容器路径）
    private static let realHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    /// DSH 数据根目录：优先 $DSH_HOME，否则 ~/.dsh
    static var dshHomePath: String? {
        if let env = ProcessInfo.processInfo.environment["DSH_HOME"], !env.isEmpty {
            return env
        }
        return (realHome as NSString).appendingPathComponent(".dsh")
    }

    private var projCacheURL: URL? {
        guard let home = Self.dshHomePath else { return nil }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("storages/session_projcache.json")
    }

    private var workspaceURL: URL? {
        guard let home = Self.dshHomePath else { return nil }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("storages/workspace.json")
    }

    private var settingsURL: URL? {
        guard let home = Self.dshHomePath else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent("settings.yaml")
    }

    // MARK: - 读取

    func loadSnapshot() -> DshLoadResult {
        guard let home = Self.dshHomePath else { return .missing }
        let fm = FileManager.default
        guard fm.fileExists(atPath: home) else {
            return .missing
        }

        guard let projCacheURL, let projData = try? Data(contentsOf: projCacheURL) else {
            return .missing
        }
        guard let projCache = try? JSONDecoder().decode(DshProjCache.self, from: projData) else {
            return .failure("解析 session_projcache.json 失败")
        }

        let workspaces = (try? JSONDecoder().decode(DshWorkspaceStore.self, from: Data(contentsOf: workspaceURL ?? URL(fileURLWithPath: "/dev/null"))))?.tables.workspaces ?? [:]
        let defaultModel = parseDefaultModel() ?? DshDefaultModel(providerID: "dsh", modelId: "unknown", variant: "default")
        let pricingRules = ModelPricingStore.load()

        // 会话 → 工作区 归属（一个会话属于一个工作区）
        var sessionToWorkspace: [String: DshWorkspace] = [:]
        for workspace in workspaces.values {
            for sessionId in workspace.sessionIds ?? [] {
                sessionToWorkspace[sessionId] = workspace
            }
        }

        var sessions: [DshSessionStat] = []
        for (id, entry) in projCache.tables.sessions {
            let workspace = sessionToWorkspace[id]
            let cwd = entry.identity.cwd
            let projectName = workspace?.title
                ?? cwd.split(separator: "/").last.map(String.init)
                ?? "(未知项目)"

            let totals = entry.rows.tokenUsage?.val.totals
            let stats = entry.rows.sessionStats?.val
            let createdAt = Date(timeIntervalSince1970: TimeInterval(entry.identity.createdAt) / 1000)

            let input = totals?.uncachedInputTokens ?? 0
            let output = totals?.outputTokens ?? 0
            let cacheRead = totals?.cacheReadTokens ?? 0
            let cacheWrite = totals?.cacheWriteTokens ?? 0

            // 费用估算：按会话创建时间 + 默认模型路由取价格（含分时窗口）
            let prices = ModelPricingStore.price(
                forModelId: defaultModel.modelId,
                variant: defaultModel.variant,
                providerID: defaultModel.providerID,
                at: createdAt,
                rules: pricingRules
            )
            let estimatedCost = Double(input) / 1_000_000 * prices.inputMiss
                + Double(cacheRead) / 1_000_000 * prices.cacheHit
                + Double(output) / 1_000_000 * prices.output

            sessions.append(DshSessionStat(
                id: id,
                title: entry.rows.title?.val ?? nil,
                createdAt: createdAt,
                cwd: cwd,
                projectName: projectName,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                turns: stats?.turns ?? 0,
                steps: stats?.steps ?? 0,
                llmMs: stats?.llmMs ?? 0,
                toolMs: stats?.toolMs ?? 0,
                ttftMs: stats?.ttftMs ?? 0,
                decodeMs: stats?.decodeMs ?? 0,
                decodeTokens: stats?.decodeTokens ?? 0,
                surfaceTokens: entry.rows.contextPressure?.val.surfaceTokens,
                contextWindow: entry.rows.contextPressure?.val.contextWindow,
                estimatedCost: estimatedCost
            ))
        }

        sessions.sort { $0.createdAt > $1.createdAt }

        // 按项目聚合
        var projectMap: [String: (name: String, path: String, sessions: Int, tokens: Int, cost: Double, lastActive: Date?)] = [:]
        for session in sessions {
            let key = session.cwd
            var item = projectMap[key] ?? (name: session.projectName, path: session.cwd, sessions: 0, tokens: 0, cost: 0, lastActive: nil)
            item.sessions += 1
            item.tokens += session.totalTokens
            item.cost += session.estimatedCost
            if let last = item.lastActive {
                if session.createdAt > last { item.lastActive = session.createdAt }
            } else {
                item.lastActive = session.createdAt
            }
            projectMap[key] = item
        }
        let projects = projectMap.values
            .map { DshProjectStat(
                id: $0.path,
                name: $0.name,
                path: $0.path,
                sessions: $0.sessions,
                totalTokens: $0.tokens,
                estimatedCost: $0.cost,
                lastActiveAt: $0.lastActive
            ) }
            .sorted { $0.sessions > $1.sessions }

        let snapshot = DshSnapshot(
            sessions: sessions,
            projects: projects,
            defaultModel: defaultModel,
            readAt: Date()
        )
        logger.notice("DSH snapshot: \(sessions.count, privacy: .public) sessions, \(projects.count, privacy: .public) projects, total=\(snapshot.totalTokens, privacy: .public)")
        return .success(snapshot)
    }

    // MARK: - settings.yaml 解析（仅 agent-default-model 段）

    private func parseDefaultModel() -> DshDefaultModel? {
        guard let settingsURL, let content = try? String(contentsOf: settingsURL, encoding: .utf8) else {
            return nil
        }

        var provider: String?
        var model: String?
        var effort: String?
        var inSection = false

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = rawLine.prefix { $0 == " " }.count
            if indent == 0 {
                inSection = trimmed.hasPrefix("agent-default-model:")
                continue
            }
            guard inSection, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
            switch key {
            case "provider": provider = value
            case "model": model = value
            case "reasoningEffort": effort = value
            default: break
            }
        }

        guard let provider, let model, !model.isEmpty else { return nil }
        // variant 归一化：max 视为 default（与 opencode 口径一致）
        let variant = (effort == nil || effort == "max") ? "default" : effort!
        return DshDefaultModel(providerID: provider, modelId: model, variant: variant)
    }
}

/// 读取结果：成功 / 未检测到 DSH 数据 / 解析失败
enum DshLoadResult {
    case success(DshSnapshot)
    case missing
    case failure(String)
}

// MARK: - L2 事件级数据源

enum DshDetailedResult {
    case success(DshDetailedDataSource)
    case missing
    case failure(String)
}

/// L2 事件级数据源：组合投影缓存（元数据）+ JSONL 事件（usage 记账），
/// 聚合出与 opencode 同构的统计条目。zstd 不可用时自动回退到投影缓存（L1）。
final class DshDetailedDataSource {
    let level: DshDetailLevel
    let snapshot: DshSnapshot
    let defaultModel: DshDefaultModel
    let events: [DshUsageEvent]
    let headers: [String: DshLogHeader]
    let pricingRules: [ModelPricingRule]
    /// 每会话消息计数（user/message + assistant/message，会话级）
    let messageCounts: [String: (user: Int, assistant: Int)]

    init(
        level: DshDetailLevel,
        snapshot: DshSnapshot,
        defaultModel: DshDefaultModel,
        events: [DshUsageEvent],
        headers: [String: DshLogHeader],
        pricingRules: [ModelPricingRule],
        messageCounts: [String: (user: Int, assistant: Int)] = [:]
    ) {
        self.level = level
        self.snapshot = snapshot
        self.defaultModel = defaultModel
        self.events = events
        self.headers = headers
        self.pricingRules = pricingRules
        self.messageCounts = messageCounts
    }

    /// 是否有事件级数据（L2）
    var isFull: Bool { level == .full }

    /// 指定会话集合的消息总数（用于 widget 消息指标；L1 回退时返回 0）
    func messageCount(forSessionIDs ids: Set<String>) -> Int {
        guard isFull else { return 0 }
        var total = 0
        for id in ids {
            if let counts = messageCounts[id] {
                total += counts.user + counts.assistant
            }
        }
        return total
    }

    // MARK: 查询

    /// 每日 × 模型用量（事件时间口径，对齐 DailyModelUsage）
    func dailyUsage(_ filter: DshTimeFilter) -> [DailyModelUsage] {
        let cal = Calendar.current
        var map: [String: DailyModelUsage] = [:]
        for event in filterEvents(filter) {
            let day = cal.startOfDay(for: event.time)
            let key = "\(day.timeIntervalSince1970)/\(event.modelKey)"
            var item = map[key] ?? DailyModelUsage(
                id: key,
                date: day,
                providerID: event.providerID,
                modelId: event.modelId,
                variant: "default",
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0,
                cacheWriteTokens: 0
            )
            item = DailyModelUsage(
                id: item.id,
                date: item.date,
                providerID: item.providerID,
                modelId: item.modelId,
                variant: item.variant,
                inputTokens: item.inputTokens + event.inputTokens,
                outputTokens: item.outputTokens + event.outputTokens,
                cacheReadTokens: item.cacheReadTokens + event.cacheReadTokens,
                reasoningTokens: item.reasoningTokens + event.reasoningTokens,
                cacheWriteTokens: item.cacheWriteTokens + event.cacheWriteTokens
            )
            map[key] = item
        }
        return map.values.sorted { $0.date < $1.date }
    }

    /// 按模型费用分解（对齐 ModelCostBreakdown；事件时间过滤）
    func modelCostBreakdown(_ filter: DshTimeFilter, referenceDate: Date) -> [ModelCostBreakdown] {
        if !isFull {
            // L1 回退：无模型归因，按项目分解
            return projectBreakdownFromSessions(filterSessions(filter), referenceDate: referenceDate)
        }

        var map: [String: (miss: Int, hit: Int, out: Int, reason: Int, write: Int, sessions: Set<String>)] = [:]
        for event in filterEvents(filter) {
            var item = map[event.modelKey] ?? (0, 0, 0, 0, 0, Set<String>())
            item.miss += event.inputTokens
            item.hit += event.cacheReadTokens
            item.out += event.outputTokens
            item.reason += event.reasoningTokens
            item.write += event.cacheWriteTokens
            item.sessions.insert(event.sessionID)
            map[event.modelKey] = item
        }

        return map.map { key, item in
            let parts = key.split(separator: "/", maxSplits: 2)
            let providerID = String(parts[0])
            let modelId = parts.count > 1 ? String(parts[1]) : "unknown"
            let pricing = ModelPricingStore.rule(
                forModelId: modelId, variant: "default", providerID: providerID, rules: pricingRules
            )
            return ModelCostBreakdown(
                id: key,
                providerID: providerID,
                modelId: modelId,
                variant: "default",
                sessions: item.sessions.count,
                cacheMissTokens: item.miss,
                cacheHitTokens: item.hit,
                outputTokens: item.out,
                reasoningTokens: item.reason,
                pricing: pricing,
                referenceDate: referenceDate
            )
        }
        .filter { $0.pricing.isEnabled }
        .sorted { $0.cacheMissTokens > $1.cacheMissTokens }
    }

    /// 会话列表（对齐 Session；时间过滤按会话创建时间 + 范围内有活动的事件时间并集）
    func sessions(_ filter: DshTimeFilter) -> [Session] {
        // 范围内有事件活动的会话
        var activeIDs = Set(filterEvents(filter).map(\.sessionID))
        // 创建时间在范围内的会话
        for session in snapshot.sessions where filter.includes(session.createdAt) {
            activeIDs.insert(session.id)
        }

        // 按会话聚合事件
        var agg: [String: (miss: Int, hit: Int, out: Int, reason: Int, write: Int, models: [String: Int])] = [:]
        for event in events {
            guard activeIDs.contains(event.sessionID) else { continue }
            var item = agg[event.sessionID] ?? (0, 0, 0, 0, 0, [:])
            item.miss += event.inputTokens
            item.hit += event.cacheReadTokens
            item.out += event.outputTokens
            item.reason += event.reasoningTokens
            item.write += event.cacheWriteTokens
            item.models[event.modelKey, default: 0] += event.totalTokensForAttribution
            agg[event.sessionID] = item
        }

        var result: [Session] = []
        for stat in snapshot.sessions where activeIDs.contains(stat.id) {
            let item = agg[stat.id] ?? (0, 0, 0, 0, 0, [:])
            // 主导模型：事件 token 最多的模型
            let dominant = item.models.max { $0.value < $1.value }?.key
            let parts = dominant?.split(separator: "/", maxSplits: 2) ?? []
            let providerID = parts.first.map(String.init) ?? defaultModel.providerID
            let modelId = parts.count > 1 ? String(parts[1]) : defaultModel.modelId
            let pricing = ModelPricingStore.rule(
                forModelId: modelId, variant: "default", providerID: providerID, rules: pricingRules
            )
            let prices = pricing.price(at: stat.createdAt)
            let cost = Double(item.miss) / 1_000_000 * prices.inputMiss
                + Double(item.hit) / 1_000_000 * prices.cacheHit
                + Double(item.out) / 1_000_000 * prices.output
                + Double(item.reason) / 1_000_000 * prices.reasoning

            result.append(Session(
                id: stat.id,
                slug: nil,
                title: stat.title,
                tokensInput: item.miss,
                tokensOutput: item.out,
                tokensReasoning: item.reason,
                tokensCacheRead: item.hit,
                tokensCacheWrite: item.write,
                cost: cost,
                providerID: providerID,
                modelId: modelId,
                modelVariant: "default",
                timeCreated: stat.createdAt,
                project: stat.projectName
            ))
        }
        return result.sorted { $0.timeCreated > $1.timeCreated }
    }

    /// 按 Agent 统计（agent = 会话日志头的 agentPreset，默认 standard）
    func agentUsage(_ filter: DshTimeFilter, referenceDate: Date) -> [AgentUsage] {
        guard isFull else { return [] }
        var map: [String: (sessions: Set<String>, miss: Int, hit: Int, out: Int, reason: Int, cost: Double)] = [:]
        for event in filterEvents(filter) {
            let agent = headers[event.sessionID]?.agentPreset ?? "unknown"
            var item = map[agent] ?? (Set<String>(), 0, 0, 0, 0, 0)
            item.sessions.insert(event.sessionID)
            item.miss += event.inputTokens
            item.hit += event.cacheReadTokens
            item.out += event.outputTokens
            item.reason += event.reasoningTokens
            map[agent] = item
        }
        return map.map { agent, item in
            let total = item.miss + item.hit + item.out + item.reason
            return AgentUsage(
                agentName: agent,
                sessions: item.sessions.count,
                inputTokens: item.miss,
                outputTokens: item.out,
                reasoningTokens: item.reason,
                cacheReadTokens: item.hit,
                totalTokens: total,
                cost: costForTokens(miss: item.miss, hit: item.hit, out: item.out, reason: item.reason, at: referenceDate)
            )
        }
        .sorted { $0.sessions > $1.sessions }
    }

    /// 按项目统计（项目 = 工作区标题 / cwd 末级）
    func projectUsage(_ filter: DshTimeFilter, referenceDate: Date) -> [ProjectUsage] {
        var map: [String: (name: String, sessions: Set<String>, miss: Int, hit: Int, out: Int, reason: Int, cost: Double)] = [:]
        let bySession = sessionAggregation(filter)
        for (sessionID, item) in bySession {
            guard let stat = snapshot.sessions.first(where: { $0.id == sessionID }) else { continue }
            var entry = map[stat.cwd] ?? (stat.projectName, Set<String>(), 0, 0, 0, 0, 0)
            entry.sessions.insert(sessionID)
            entry.miss += item.miss
            entry.hit += item.hit
            entry.out += item.out
            entry.reason += item.reason
            map[stat.cwd] = entry
        }
        return map.map { _, item in
            ProjectUsage(
                projectId: item.name,
                projectName: item.name,
                worktree: "/",
                sessions: item.sessions.count,
                inputTokens: item.miss,
                outputTokens: item.out,
                reasoningTokens: item.reason,
                cacheReadTokens: item.hit,
                totalTokens: item.miss + item.hit + item.out + item.reason,
                cost: costForTokens(miss: item.miss, hit: item.hit, out: item.out, reason: item.reason, at: referenceDate)
            )
        }
        .sorted { $0.sessions > $1.sessions }
    }

    /// 可用年月（事件日期 ∪ 会话创建日期）
    func periods() -> [TimePeriod] {
        let cal = Calendar.current
        var seen = Set<String>()
        var result: [TimePeriod] = []
        func add(_ date: Date) {
            let comps = cal.dateComponents([.year, .month], from: date)
            let year = String(comps.year ?? 0)
            let month = String(format: "%02d", comps.month ?? 0)
            let key = "\(year)/\(month)"
            if seen.insert(key).inserted {
                result.append(TimePeriod(year: year, month: month))
            }
        }
        for event in events { add(event.time) }
        for session in snapshot.sessions { add(session.createdAt) }
        return result.sorted { ($0.year, $0.month ?? "") > ($1.year, $1.month ?? "") }
    }

    /// 某年月的可用日
    func days(year: String?, month: String?) -> [String] {
        guard let year, let month else { return [] }
        let cal = Calendar.current
        var days: Set<String> = []
        func add(_ date: Date) {
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            if String(comps.year ?? 0) == year, String(format: "%02d", comps.month ?? 0) == month {
                days.insert(String(format: "%02d", comps.day ?? 0))
            }
        }
        for event in events { add(event.time) }
        for session in snapshot.sessions { add(session.createdAt) }
        return days.sorted()
    }

    // MARK: 内部

    private func filterEvents(_ filter: DshTimeFilter) -> [DshUsageEvent] {
        events.filter { filter.includes($0.time) }
    }

    private func filterSessions(_ filter: DshTimeFilter) -> [DshSessionStat] {
        snapshot.sessions.filter { filter.includes($0.createdAt) }
    }

    /// 按会话聚合事件（token 桶 + 主导模型候选）
    private func sessionAggregation(_ filter: DshTimeFilter) -> [String: (miss: Int, hit: Int, out: Int, reason: Int, write: Int)] {
        var agg: [String: (miss: Int, hit: Int, out: Int, reason: Int, write: Int)] = [:]
        for event in filterEvents(filter) {
            var item = agg[event.sessionID] ?? (0, 0, 0, 0, 0)
            item.miss += event.inputTokens
            item.hit += event.cacheReadTokens
            item.out += event.outputTokens
            item.reason += event.reasoningTokens
            item.write += event.cacheWriteTokens
            agg[event.sessionID] = item
        }
        return agg
    }

    /// L1 回退：按项目（会话）聚合为费用分解行
    private func projectBreakdownFromSessions(_ sessions: [DshSessionStat], referenceDate: Date) -> [ModelCostBreakdown] {
        var map: [String: (name: String, sessions: Int, miss: Int, hit: Int, out: Int)] = [:]
        for session in sessions {
            var item = map[session.cwd] ?? (session.projectName, 0, 0, 0, 0)
            item.sessions += 1
            item.miss += session.inputTokens
            item.hit += session.cacheReadTokens
            item.out += session.outputTokens
            map[session.cwd] = item
        }
        let pricing = ModelPricingStore.rule(
            forModelId: defaultModel.modelId,
            variant: defaultModel.variant,
            providerID: defaultModel.providerID,
            rules: pricingRules
        )
        return map.values
            .map { item in
                ModelCostBreakdown(
                    id: item.name,
                    providerID: defaultModel.providerID,
                    modelId: defaultModel.modelId,
                    variant: defaultModel.variant,
                    sessions: item.sessions,
                    cacheMissTokens: item.miss,
                    cacheHitTokens: item.hit,
                    outputTokens: item.out,
                    reasoningTokens: 0,
                    pricing: pricing,
                    referenceDate: referenceDate,
                    displayNameOverride: item.name
                )
            }
            .sorted { $0.cacheMissTokens > $1.cacheMissTokens }
    }

    private func costForTokens(miss: Int, hit: Int, out: Int, reason: Int, at date: Date) -> Double {
        let prices = ModelPricingStore.price(
            forModelId: defaultModel.modelId,
            variant: defaultModel.variant,
            providerID: defaultModel.providerID,
            at: date,
            rules: pricingRules
        )
        return Double(miss) / 1_000_000 * prices.inputMiss
            + Double(hit) / 1_000_000 * prices.cacheHit
            + Double(out) / 1_000_000 * prices.output
            + Double(reason) / 1_000_000 * prices.reasoning
    }
}

extension DshUsageEvent {
    /// 用于主导模型归因的 token 权重（输入 + 输出 + 缓存）
    var totalTokensForAttribution: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

extension DshService {
    /// 读取 L2 事件级数据源（自动回退 L1）
    func loadDetailedData() -> DshDetailedResult {
        guard let home = Self.dshHomePath, FileManager.default.fileExists(atPath: home) else {
            return .missing
        }

        switch loadSnapshot() {
        case .success(let snapshot):
            let eventsBySession = DshEventStore.shared.loadAll()
            var allEvents: [DshUsageEvent] = []
            var headers: [String: DshLogHeader] = [:]
            var messageCounts: [String: (user: Int, assistant: Int)] = [:]
            for (sessionID, item) in eventsBySession {
                if let header = item.header {
                    headers[sessionID] = header
                }
                allEvents.append(contentsOf: item.events)
                if item.userMessages > 0 || item.assistantMessages > 0 {
                    messageCounts[sessionID] = (item.userMessages, item.assistantMessages)
                }
            }
            let level: DshDetailLevel = allEvents.isEmpty ? .totalsOnly : .full
            let defaultModel = snapshot.defaultModel
                ?? DshDefaultModel(providerID: "dsh", modelId: "unknown", variant: "default")
            let dataSource = DshDetailedDataSource(
                level: level,
                snapshot: snapshot,
                defaultModel: defaultModel,
                events: allEvents,
                headers: headers,
                pricingRules: ModelPricingStore.load(),
                messageCounts: messageCounts
            )
            if level == .totalsOnly {
                dataSourceLogger.notice("DSH L2: 无事件数据（zstd 不可用或日志为空），回退 L1")
            } else {
                dataSourceLogger.notice("DSH L2: \(allEvents.count, privacy: .public) 条 usage 事件")
            }
            return .success(dataSource)

        case .missing:
            return .missing
        case .failure(let message):
            return .failure(message)
        }
    }
}

private let dataSourceLogger = Logger(subsystem: "com.luoyun.tokencheck", category: "dsh-l2")
