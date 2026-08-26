import Combine
import Foundation

class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""
    @Published var sessionRollbacks: [String: RollbackRecord] = [:]
    @Published var periods: [TimePeriod] = []
    @Published var filterMode: TimeFilterMode = .day
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
    @Published var selectedDay: String? = {
        String(format: "%02d", Calendar.current.component(.day, from: Date()))
    }()
    @Published var availableDays: [String] = []
    @Published var showRollback: Bool {
        didSet { defaults.set(showRollback, forKey: Self.showRollbackKey) }
    }
    @Published var dataSource: StatsDataSource {
        didSet { defaults.set(dataSource.rawValue, forKey: Self.dataSourceKey) }
    }
    @Published var dshLevel: DshDetailLevel = .full

    private var hasInitialized = false

    var hasSessionRollback: Bool {
        sessionRollbacks.values.contains { $0.total > 0 }
    }

    private let defaults = UserDefaults.standard
    private static let showRollbackKey = "session_showRollback"
    private static let dataSourceKey = "session_dataSource"

    init() {
        showRollback = defaults.object(forKey: Self.showRollbackKey) as? Bool ?? true
        dataSource = StatsDataSource(rawValue: defaults.string(forKey: Self.dataSourceKey) ?? "") ?? .opencode
    }

    var availableYears: [String] {
        let years = Set(periods.map(\.year))
        return ["全部"] + years.sorted(by: >)
    }

    var availableMonths: [String] {
        guard let year = selectedYear else { return [] }
        let months = periods.filter { $0.year == year }.compactMap { $0.month }
        return ["全部"] + months.sorted()
    }

    var filteredSessions: [Session] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(searchText)
                || $0.modelId.localizedCaseInsensitiveContains(searchText)
                || ($0.project ?? "").localizedCaseInsensitiveContains(searchText)
        }
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

    private func selectInitialDayIfNeeded() {
        guard !hasInitialized, filterMode == .day else { return }
        hasInitialized = true
        resolveInitialDay()
    }

    /// 首次加载时确定目标日：今天有数据则今天，否则往过去逐月回溯找最近有数据的日。
    /// 仅由 load 的后台任务调用一次。
    private func resolveInitialDay() {
        let cal = Calendar.current
        let now = Date()
        let todayYear = String(cal.component(.year, from: now))
        let todayMonth = String(format: "%02d", cal.component(.month, from: now))
        let todayDay = String(format: "%02d", cal.component(.day, from: now))

        for period in availablePeriods() {
            let year = period.year
            guard let month = period.month, !year.isEmpty else { continue }
            if year > todayYear || (year == todayYear && month > todayMonth) { continue }

            let days = availableDays(year: year, month: month)
            guard !days.isEmpty else { continue }

            let target: String
            if year == todayYear && month == todayMonth {
                guard let latest = days.filter({ $0 <= todayDay }).max() else { continue }
                target = latest
            } else {
                guard let latest = days.max() else { continue }
                target = latest
            }
            selectedYear = year
            selectedMonth = month
            selectedDay = target
            return
        }
    }

    private func availablePeriods() -> [TimePeriod] {
        switch dataSource {
        case .opencode:
            guard let service = DatabaseService.shared,
                  let periods = try? service.fetchAvailablePeriods() else { return [] }
            return periods
        case .dsh:
            guard case .success(let dataSource) = DshService.shared.loadDetailedData() else { return [] }
            return dataSource.periods()
        case .all:
            var combined: [TimePeriod] = []
            if let service = DatabaseService.shared, let p = try? service.fetchAvailablePeriods() {
                combined.append(contentsOf: p)
            }
            if case .success(let dsh) = DshService.shared.loadDetailedData() {
                combined.append(contentsOf: dsh.periods())
            }
            return Self.mergePeriods(combined, [])
        }
    }

    private func availableDays(year: String, month: String) -> [String] {
        switch dataSource {
        case .opencode:
            guard let service = DatabaseService.shared,
                  let days = try? service.fetchAvailableDays(year: year, month: month) else { return [] }
            return days
        case .dsh:
            guard case .success(let dataSource) = DshService.shared.loadDetailedData() else { return [] }
            return dataSource.days(year: year, month: month)
        case .all:
            var combined: [String] = []
            if let service = DatabaseService.shared, let d = try? service.fetchAvailableDays(year: year, month: month) {
                combined.append(contentsOf: d)
            }
            if case .success(let dsh) = DshService.shared.loadDetailedData() {
                combined.append(contentsOf: dsh.days(year: year, month: month))
            }
            return Self.mergeDays(combined, [])
        }
    }

    // MARK: - 数据获取（opencode / DSH）

    private func currentFilter() -> DshTimeFilter {
        if filterMode == .range {
            return DshTimeFilter(from: startDate, to: endDate, year: nil, month: nil, day: nil)
        }
        return DshTimeFilter(from: nil, to: nil, year: selectedYear, month: selectedMonth, day: selectedDay)
    }

    private struct OpencodeSessionData {
        let sessions: [Session]
        let periods: [TimePeriod]
        let days: [String]
        let rollbacks: [String: RollbackRecord]
    }

    private func fetchOpencodeData() throws -> OpencodeSessionData {
        if let ds = DatabaseService.shared, let db = ds.db {
            TokenDeltaTracker.shared.refresh(db: db)
        }
        guard let service = DatabaseService.shared else { throw DatabaseError.cannotOpen("") }
        let rb = TokenDeltaTracker.shared.sessionRollbacks
        let periods = try service.fetchAvailablePeriods()
        let sessions: [Session]
        if filterMode == .range {
            sessions = try service.fetchSessions(from: startDate, to: endDate, limit: 200)
        } else {
            sessions = try service.fetchSessions(year: selectedYear, month: selectedMonth, day: selectedDay, limit: 200)
        }

        var days: [String] = []
        if filterMode == .day, let year = selectedYear, let month = selectedMonth {
            days = try service.fetchAvailableDays(year: year, month: month)
        }

        return OpencodeSessionData(sessions: sessions, periods: periods, days: days, rollbacks: rb)
    }

    private struct DshSessionData {
        let sessions: [Session]
        let periods: [TimePeriod]
        let days: [String]
        let level: DshDetailLevel
    }

    private func fetchDshData() -> DshSessionData? {
        guard case .success(let dataSource) = DshService.shared.loadDetailedData() else {
            return nil
        }
        let sessions = dataSource.sessions(currentFilter())
        var days: [String] = []
        if filterMode == .day {
            days = dataSource.days(year: selectedYear, month: selectedMonth)
        }
        return DshSessionData(sessions: sessions, periods: dataSource.periods(), days: days, level: dataSource.level)
    }

    // MARK: - opencode 数据源

    private func loadOpencode() {
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            self.selectInitialDayIfNeeded()
            do {
                let data = try self.fetchOpencodeData()
                DispatchQueue.main.async {
                    self.periods = data.periods
                    self.sessions = data.sessions
                    self.availableDays = ["全部"] + data.days
                    self.sessionRollbacks = data.rollbacks
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

    // MARK: - DSH 数据源

    private func loadDsh() {
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            self.selectInitialDayIfNeeded()

            switch DshService.shared.loadDetailedData() {
            case .success(let dataSource):
                let data = self.fetchDshData() ?? DshSessionData(sessions: [], periods: dataSource.periods(), days: [], level: dataSource.level)
                DispatchQueue.main.async {
                    self.periods = data.periods
                    self.sessions = data.sessions
                    self.availableDays = ["全部"] + data.days
                    self.sessionRollbacks = [:]
                    self.dshLevel = data.level
                    self.isLoading = false
                }
            case .missing:
                DispatchQueue.main.async {
                    self.sessions = []
                    self.periods = []
                    self.availableDays = []
                    self.error = "未检测到 DSH 数据（\(DshService.dshHomePath ?? "~/.dsh") 下无投影缓存）。\n请先通过 DeepSeek Harness 开始至少一个会话。"
                    self.isLoading = false
                }
            case .failure(let message):
                DispatchQueue.main.async {
                    self.sessions = []
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
            self.selectInitialDayIfNeeded()

            var ocError: String?
            var ocData: OpencodeSessionData?
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

            // 按时间倒序合并（opencode 在前，DSH 会话 id 前缀不同不会冲突）
            var merged = (ocData?.sessions ?? []) + (dshData?.sessions ?? [])
            merged.sort { $0.timeCreated > $1.timeCreated }

            let mergedPeriods = Self.mergePeriods(ocData?.periods ?? [], dshData?.periods ?? [])
            let mergedDays = Self.mergeDays(ocData?.days ?? [], dshData?.days ?? [])

            DispatchQueue.main.async {
                self.periods = mergedPeriods
                self.sessions = merged
                self.availableDays = ["全部"] + mergedDays
                self.sessionRollbacks = ocData?.rollbacks ?? [:]
                self.dshLevel = dshData?.level ?? .missing
                self.isLoading = false
            }
        }
    }

    private static func mergePeriods(_ a: [TimePeriod], _ b: [TimePeriod]) -> [TimePeriod] {
        let combined = Dictionary((a + b).map { ("\($0.year)/\($0.month ?? "")", $0) }) { _, new in new }
        return combined.values.sorted { ($0.year, $0.month ?? "") > ($1.year, $1.month ?? "") }
    }

    private static func mergeDays(_ a: [String], _ b: [String]) -> [String] {
        Array(Set(a + b)).sorted()
    }
}
