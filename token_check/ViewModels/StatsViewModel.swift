import Combine
import Foundation

enum StatsSegment: String, CaseIterable {
    case agent = "Agent"
    case project = "项目"
    case efficiency = "效率"

    var icon: String {
        switch self {
        case .agent: return "cpu.fill"
        case .project: return "folder.fill"
        case .efficiency: return "scissors"
        }
    }
}

class StatsViewModel: ObservableObject {
    @Published var filterMode: TimeFilterMode = .range
    @Published var startDate: Date = {
        let cal = Calendar.current
        let now = Date()
        return cal.date(from: DateComponents(year: cal.component(.year, from: now), month: cal.component(.month, from: now), day: 1)) ?? now
    }()
    @Published var endDate: Date = Date()
    @Published var selectedYear: String? = {
        String(Calendar.current.component(.year, from: Date()))
    }()
    @Published var selectedMonth: String? = {
        String(format: "%02d", Calendar.current.component(.month, from: Date()))
    }()
    @Published var selectedDay: String? = nil
    @Published var availablePeriods: [TimePeriod] = []
    @Published var availableDays: [String] = []

    @Published var agentUsage: [AgentUsage] = []
    @Published var projectUsage: [ProjectUsage] = []
    @Published var efficiencySummary = ProductivitySummary(totalAdditions: 0, totalDeletions: 0, totalFiles: 0, sessionsWithChanges: 0, totalTokens: 0)
    @Published var efficiencyDetails: [SessionEfficiency] = []

    @Published var isLoading = false
    @Published var error: String?
    @Published var dataSource: StatsDataSource {
        didSet { defaults.set(dataSource.rawValue, forKey: Self.dataSourceKey) }
    }
    @Published var dshLevel: DshDetailLevel = .full

    private let defaults = UserDefaults.standard
    private static let dataSourceKey = "stats_dataSource"

    init() {
        dataSource = StatsDataSource(rawValue: defaults.string(forKey: Self.dataSourceKey) ?? "") ?? .opencode
    }

    var availableYears: [String] {
        let years = Set(availablePeriods.map(\.year))
        return ["全部"] + years.sorted(by: >)
    }

    var availableMonths: [String] {
        guard let year = selectedYear else { return [] }
        let months = availablePeriods.filter { $0.year == year }.compactMap { $0.month }
        return ["全部"] + months.sorted()
    }

    func load() {
        isLoading = true
        error = nil

        switch dataSource {
        case .opencode: loadOpencode()
        case .dsh: loadDsh()
        case .all: loadAll()
        }
    }

    func applyFilter() {
        load()
    }

    // MARK: - 数据获取（opencode / DSH）

    private func currentFilter() -> DshTimeFilter {
        if filterMode == .range {
            return DshTimeFilter(from: startDate, to: endDate, year: nil, month: nil, day: nil)
        }
        return DshTimeFilter(from: nil, to: nil, year: selectedYear, month: selectedMonth, day: selectedDay)
    }

    private var referenceDate: Date {
        filterMode == .range ? endDate : .now
    }

    private struct OpencodeStatsData {
        let agents: [AgentUsage]
        let projects: [ProjectUsage]
        let efficiencySummary: ProductivitySummary
        let efficiencyDetails: [SessionEfficiency]
        let periods: [TimePeriod]
        let days: [String]
    }

    private func fetchOpencodeData() throws -> OpencodeStatsData {
        if let ds = DatabaseService.shared, let db = ds.db {
            TokenDeltaTracker.shared.refresh(db: db)
        }
        guard let service = DatabaseService.shared else { throw DatabaseError.cannotOpen("") }
        let periods = try service.fetchAvailablePeriods()

        let agents = try service.fetchAgentUsage(
            year: selectedYear, month: selectedMonth, day: selectedDay,
            from: filterMode == .range ? startDate : nil,
            to: filterMode == .range ? endDate : nil
        )
        let projects = try service.fetchProjectUsage(
            year: selectedYear, month: selectedMonth, day: selectedDay,
            from: filterMode == .range ? startDate : nil,
            to: filterMode == .range ? endDate : nil
        )
        let effSummary = try service.fetchEfficiencySummary(
            year: selectedYear, month: selectedMonth, day: selectedDay,
            from: filterMode == .range ? startDate : nil,
            to: filterMode == .range ? endDate : nil
        )
        let effDetails = try service.fetchEfficiencyDetail(
            year: selectedYear, month: selectedMonth, day: selectedDay,
            from: filterMode == .range ? startDate : nil,
            to: filterMode == .range ? endDate : nil
        )

        var days: [String] = []
        if filterMode == .day, let year = selectedYear, let month = selectedMonth {
            days = try service.fetchAvailableDays(year: year, month: month)
        }

        return OpencodeStatsData(
            agents: agents,
            projects: projects,
            efficiencySummary: effSummary,
            efficiencyDetails: effDetails,
            periods: periods,
            days: days
        )
    }

    private struct DshStatsData {
        let agents: [AgentUsage]
        let projects: [ProjectUsage]
        let periods: [TimePeriod]
        let days: [String]
        let level: DshDetailLevel
    }

    private func fetchDshData() -> DshStatsData? {
        guard case .success(let dataSource) = DshService.shared.loadDetailedData() else {
            return nil
        }
        let filter = currentFilter()
        let agents = dataSource.agentUsage(filter, referenceDate: referenceDate)
        let projects = dataSource.projectUsage(filter, referenceDate: referenceDate)
        var days: [String] = []
        if filterMode == .day {
            days = dataSource.days(year: selectedYear, month: selectedMonth)
        }
        return DshStatsData(
            agents: agents,
            projects: projects,
            periods: dataSource.periods(),
            days: days,
            level: dataSource.level
        )
    }

    // MARK: - opencode 数据源

    private func loadOpencode() {
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            do {
                let data = try self.fetchOpencodeData()
                DispatchQueue.main.async {
                    self.availablePeriods = data.periods
                    self.agentUsage = data.agents
                    self.projectUsage = data.projects
                    self.efficiencySummary = data.efficiencySummary
                    self.efficiencyDetails = data.efficiencyDetails
                    self.availableDays = ["全部"] + data.days
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - DSH 数据源（DSH 无效率统计）

    private func loadDsh() {
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }

            switch DshService.shared.loadDetailedData() {
            case .success(let dataSource):
                let data = self.fetchDshData() ?? DshStatsData(
                    agents: [], projects: [], periods: dataSource.periods(), days: [], level: dataSource.level
                )
                DispatchQueue.main.async {
                    self.availablePeriods = data.periods
                    self.agentUsage = data.agents
                    self.projectUsage = data.projects
                    self.efficiencySummary = ProductivitySummary(
                        totalAdditions: 0, totalDeletions: 0, totalFiles: 0,
                        sessionsWithChanges: 0, totalTokens: 0
                    )
                    self.efficiencyDetails = []
                    self.availableDays = ["全部"] + data.days
                    self.dshLevel = data.level
                    self.isLoading = false
                }
            case .missing:
                DispatchQueue.main.async {
                    self.availablePeriods = []
                    self.agentUsage = []
                    self.projectUsage = []
                    self.availableDays = []
                    self.error = "未检测到 DSH 数据（\(DshService.dshHomePath ?? "~/.dsh") 下无投影缓存）。\n请先通过 DeepSeek Harness 开始至少一个会话。"
                    self.isLoading = false
                }
            case .failure(let message):
                DispatchQueue.main.async {
                    self.agentUsage = []
                    self.projectUsage = []
                    self.error = message
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - 合并统计（opencode + DSH）

    private func loadAll() {
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }

            var ocError: String?
            var ocData: OpencodeStatsData?
            do {
                ocData = try self.fetchOpencodeData()
            } catch {
                ocError = error.localizedDescription
            }
            let dshData = self.fetchDshData()

            if ocData == nil, dshData == nil {
                DispatchQueue.main.async {
                    self.error = ocError ?? "未检测到 DSH 数据（\(DshService.dshHomePath ?? "~/.dsh") 下无投影缓存）"
                    self.isLoading = false
                }
                return
            }

            let mergedAgents = Self.mergeAgents(ocData?.agents ?? [], dshData?.agents ?? [])
            let mergedProjects = Self.mergeProjects(ocData?.projects ?? [], dshData?.projects ?? [])
            let mergedPeriods = Self.mergePeriods(ocData?.periods ?? [], dshData?.periods ?? [])
            let mergedDays = Self.mergeDays(ocData?.days ?? [], dshData?.days ?? [])

            DispatchQueue.main.async {
                self.availablePeriods = mergedPeriods
                self.agentUsage = mergedAgents
                self.projectUsage = mergedProjects
                // 效率统计只有 opencode 有（DSH 无代码变更数据）
                self.efficiencySummary = ocData?.efficiencySummary ?? ProductivitySummary(
                    totalAdditions: 0, totalDeletions: 0, totalFiles: 0,
                    sessionsWithChanges: 0, totalTokens: 0
                )
                self.efficiencyDetails = ocData?.efficiencyDetails ?? []
                self.availableDays = ["全部"] + mergedDays
                self.dshLevel = dshData?.level ?? .missing
                self.isLoading = false
            }
        }
    }

    private static func mergeAgents(_ a: [AgentUsage], _ b: [AgentUsage]) -> [AgentUsage] {
        var map: [String: AgentUsage] = [:]
        for item in a + b {
            if let existing = map[item.agentName] {
                map[item.agentName] = AgentUsage(
                    agentName: existing.agentName,
                    sessions: existing.sessions + item.sessions,
                    inputTokens: existing.inputTokens + item.inputTokens,
                    outputTokens: existing.outputTokens + item.outputTokens,
                    reasoningTokens: existing.reasoningTokens + item.reasoningTokens,
                    cacheReadTokens: existing.cacheReadTokens + item.cacheReadTokens,
                    totalTokens: existing.totalTokens + item.totalTokens,
                    cost: existing.cost + item.cost
                )
            } else {
                map[item.agentName] = item
            }
        }
        return map.values.sorted { $0.sessions > $1.sessions }
    }

    private static func mergeProjects(_ a: [ProjectUsage], _ b: [ProjectUsage]) -> [ProjectUsage] {
        var map: [String: ProjectUsage] = [:]
        for item in a + b {
            if let existing = map[item.projectId] {
                map[item.projectId] = ProjectUsage(
                    projectId: existing.projectId,
                    projectName: existing.projectName.isEmpty ? item.projectName : existing.projectName,
                    worktree: existing.worktree == "/" ? item.worktree : existing.worktree,
                    sessions: existing.sessions + item.sessions,
                    inputTokens: existing.inputTokens + item.inputTokens,
                    outputTokens: existing.outputTokens + item.outputTokens,
                    reasoningTokens: existing.reasoningTokens + item.reasoningTokens,
                    cacheReadTokens: existing.cacheReadTokens + item.cacheReadTokens,
                    totalTokens: existing.totalTokens + item.totalTokens,
                    cost: existing.cost + item.cost
                )
            } else {
                map[item.projectId] = item
            }
        }
        return map.values.sorted { $0.sessions > $1.sessions }
    }

    private static func mergePeriods(_ a: [TimePeriod], _ b: [TimePeriod]) -> [TimePeriod] {
        let combined = Dictionary((a + b).map { ("\($0.year)/\($0.month ?? "")", $0) }) { _, new in new }
        return combined.values.sorted { ($0.year, $0.month ?? "") > ($1.year, $1.month ?? "") }
    }

    private static func mergeDays(_ a: [String], _ b: [String]) -> [String] {
        Array(Set(a + b)).sorted()
    }
}
