import Combine
import Foundation

class DailyTrendViewModel: ObservableObject {
    enum TimeMode: String, CaseIterable {
        case last7 = "7天"
        case last14 = "14天"
        case last30 = "30天"
        case last90 = "90天"
        case monthly = "按月"
        case custom = "自定义"
    }

    enum MetricType: String, CaseIterable {
        case total = "总 Tokens"
        case input = "输入（未命中）"
        case cacheHit = "缓存命中"
        case output = "输出"
    }

    enum ChartMode: String, CaseIterable {
        case token = "Token"
        case cost = "费用"
    }

    @Published var timeMode: TimeMode = .last7
    @Published var selectedMetric: MetricType = .total
    @Published var chartMode: ChartMode = .token
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
    @Published var selectedDay: String? = {
        String(format: "%02d", Calendar.current.component(.day, from: Date()))
    }()
    @Published var availableDays: [String] = []
    @Published var periods: [TimePeriod] = []
    @Published var dailyData: [DailyModelUsage] = []
    @Published var selectedModels: Set<String> = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var rolledBackTotal: Int = 0
    @Published var dataSource: StatsDataSource {
        didSet { defaults.set(dataSource.rawValue, forKey: Self.dataSourceKey) }
    }
    @Published var dshLevel: DshDetailLevel = .full

    private let defaults = UserDefaults.standard
    private static let dataSourceKey = "trend_dataSource"

    init() {
        dataSource = StatsDataSource(rawValue: defaults.string(forKey: Self.dataSourceKey) ?? "") ?? .opencode
    }

    var days: Int {
        switch timeMode {
        case .last7: return 7
        case .last14: return 14
        case .last30: return 30
        case .last90: return 90
        case .monthly, .custom: return 0
        }
    }

    var isMonthlyMode: Bool { timeMode == .monthly }
    var isCustomMode: Bool { timeMode == .custom }

    var availableModels: [String] {
        Array(Set(dailyData.map(\.displayName))).sorted()
    }

    var filteredData: [DailyModelUsage] {
        if selectedModels.isEmpty {
            return dailyData
        }
        return dailyData.filter { selectedModels.contains($0.displayName) }
    }

    var pricingLookup: [String: ModelPricingRule] {
        ModelPricingStore.lookup(from: ModelPricingStore.load())
    }

    func cost(for item: DailyModelUsage, metric: MetricType) -> Double {
        let key = "\(item.providerID)/\(item.modelId)/\(item.variant)"
        let pricing = pricingLookup[key] ?? .defaults(providerID: item.providerID, modelId: item.modelId, variant: item.variant)
        let prices = pricing.price(at: item.date)
        switch metric {
        case .total:
            return Double(item.inputTokens) / 1_000_000 * prices.inputMiss
                + Double(item.cacheReadTokens) / 1_000_000 * prices.cacheHit
                + Double(item.outputTokens) / 1_000_000 * prices.output
                + Double(item.reasoningTokens) / 1_000_000 * prices.reasoning
        case .input:
            return Double(item.inputTokens) / 1_000_000 * prices.inputMiss
        case .cacheHit:
            return Double(item.cacheReadTokens) / 1_000_000 * prices.cacheHit
        case .output:
            return Double(item.outputTokens) / 1_000_000 * prices.output
        }
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

    private struct TrendQuery {
        let start: Date?
        let end: Date?
    }

    /// 按当前时间模式计算查询范围（opencode 与 DSH 共用口径）
    private func computeQueryRange() -> TrendQuery {
        let cal = Calendar.current
        if isCustomMode {
            return TrendQuery(start: startDate, end: endDate)
        }
        if isMonthlyMode {
            if let year = selectedYear, let month = selectedMonth {
                if filterMode == .day, let day = selectedDay {
                    let date = Self.dateFrom(year: year, month: month, day: day)
                    return TrendQuery(start: date, end: date)
                }
                return TrendQuery(
                    start: Self.dateFrom(year: year, month: month),
                    end: Self.lastDayOf(year: year, month: month)
                )
            }
            return TrendQuery(start: nil, end: nil)
        }
        let today = cal.startOfDay(for: Date())
        return TrendQuery(
            start: cal.date(byAdding: .day, value: -(days - 1), to: today),
            end: today
        )
    }

    private struct OpencodeTrendData {
        let data: [DailyModelUsage]
        let periods: [TimePeriod]
        let days: [String]
        let rbTotal: Int
    }

    /// opencode 每日按模型数据（未填充缺失日；失败抛错）
    private func fetchOpencodeData() throws -> OpencodeTrendData {
        if let ds = DatabaseService.shared, let db = ds.db {
            TokenDeltaTracker.shared.refresh(db: db)
        }
        guard let service = DatabaseService.shared else { throw DatabaseError.cannotOpen("") }
        let query = computeQueryRange()
        let rbTotal: Int
        var data: [DailyModelUsage]
        if let qs = query.start, let qe = query.end {
            rbTotal = TokenDeltaTracker.shared.rollback(from: qs, to: qe).total
            data = TokenDeltaTracker.shared.dailyModelUsage(from: qs, to: qe)
            data = try service.fetchDailyUsageByModel(from: qs, to: qe)
        } else if isMonthlyMode {
            rbTotal = TokenDeltaTracker.shared.rollback(year: selectedYear, month: selectedMonth, day: filterMode == .day ? selectedDay : nil).total
            data = try service.fetchDailyUsageByModel(
                year: selectedYear, month: selectedMonth, day: filterMode == .day ? selectedDay : nil
            )
        } else {
            rbTotal = 0
            data = []
        }

        let periods = try service.fetchAvailablePeriods()

        var days: [String] = []
        if isMonthlyMode, let year = selectedYear, let month = selectedMonth {
            days = try service.fetchAvailableDays(year: year, month: month)
        }

        return OpencodeTrendData(data: data, periods: periods, days: days, rbTotal: rbTotal)
    }

    private struct DshTrendData {
        let data: [DailyModelUsage]
        let periods: [TimePeriod]
        let days: [String]
        let level: DshDetailLevel
    }

    /// DSH 每日按模型数据（事件级；zstd 不可用时为空并回退 L1）
    private func fetchDshData() -> DshTrendData? {
        guard case .success(let dataSource) = DshService.shared.loadDetailedData() else {
            return nil
        }
        let query = computeQueryRange()
        var data: [DailyModelUsage] = []
        if let qs = query.start, let qe = query.end {
            data = dataSource.dailyUsage(DshTimeFilter(from: qs, to: qe, year: nil, month: nil, day: nil))
        } else if isMonthlyMode {
            data = dataSource.dailyUsage(DshTimeFilter(
                from: nil, to: nil,
                year: selectedYear, month: selectedMonth,
                day: filterMode == .day ? selectedDay : nil
            ))
        }
        var days: [String] = []
        if isMonthlyMode {
            days = dataSource.days(year: selectedYear, month: selectedMonth)
        }
        return DshTrendData(data: data, periods: dataSource.periods(), days: days, level: dataSource.level)
    }

    // MARK: - opencode 数据源

    private func loadOpencode() {
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            do {
                let raw = try self.fetchOpencodeData()
                let filled = self.fill(raw.data)
                DispatchQueue.main.async {
                    self.periods = raw.periods
                    self.dailyData = filled
                    self.availableDays = ["全部"] + raw.days
                    self.rolledBackTotal = raw.rbTotal
                    let availableModels = Set(filled.map(\.displayName))
                    let preservedSelection = self.selectedModels.intersection(availableModels)
                    self.selectedModels = preservedSelection.isEmpty ? availableModels : preservedSelection
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

            switch DshService.shared.loadDetailedData() {
            case .success(let dataSource):
                let raw = self.fetchDshData() ?? DshTrendData(data: [], periods: dataSource.periods(), days: [], level: dataSource.level)
                let filled = self.fill(raw.data)
                DispatchQueue.main.async {
                    self.periods = raw.periods
                    self.dailyData = filled
                    self.availableDays = ["全部"] + raw.days
                    self.rolledBackTotal = 0
                    self.dshLevel = raw.level
                    let availableModels = Set(filled.map(\.displayName))
                    let preservedSelection = self.selectedModels.intersection(availableModels)
                    self.selectedModels = preservedSelection.isEmpty ? availableModels : preservedSelection
                    self.isLoading = false
                }
            case .missing:
                DispatchQueue.main.async {
                    self.dailyData = []
                    self.periods = []
                    self.availableDays = []
                    self.error = "未检测到 DSH 数据（\(DshService.dshHomePath ?? "~/.dsh") 下无投影缓存）。\n请先通过 DeepSeek Harness 开始至少一个会话。"
                    self.isLoading = false
                }
            case .failure(let message):
                DispatchQueue.main.async {
                    self.dailyData = []
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
            var ocRaw: OpencodeTrendData?
            do {
                ocRaw = try self.fetchOpencodeData()
            } catch {
                ocError = error.localizedDescription
            }
            let dshRaw = self.fetchDshData()

            if ocRaw == nil, dshRaw == nil {
                DispatchQueue.main.async {
                    self.error = ocError ?? "未检测到 DSH 数据（\(DshService.dshHomePath ?? "~/.dsh") 下无投影缓存）"
                    self.isLoading = false
                }
                return
            }

            let merged = Self.mergeDailyUsages(ocRaw?.data ?? [], dshRaw?.data ?? [])
            let filled = self.fill(merged)
            let mergedPeriods = Self.mergePeriods(ocRaw?.periods ?? [], dshRaw?.periods ?? [])
            let mergedDays = Self.mergeDays(ocRaw?.days ?? [], dshRaw?.days ?? [])

            DispatchQueue.main.async {
                self.periods = mergedPeriods
                self.dailyData = filled
                self.availableDays = ["全部"] + mergedDays
                self.rolledBackTotal = ocRaw?.rbTotal ?? 0
                self.dshLevel = dshRaw?.level ?? .missing
                let availableModels = Set(filled.map(\.displayName))
                let preservedSelection = self.selectedModels.intersection(availableModels)
                self.selectedModels = preservedSelection.isEmpty ? availableModels : preservedSelection
                self.isLoading = false
            }
        }
    }

    /// 按 (日期, 模型) 合并两套每日数据
    static func mergeDailyUsages(_ a: [DailyModelUsage], _ b: [DailyModelUsage]) -> [DailyModelUsage] {
        var map: [String: DailyModelUsage] = [:]
        for item in a + b {
            let key = "\(item.date.timeIntervalSince1970)/\(item.modelKey)"
            if let existing = map[key] {
                map[key] = DailyModelUsage(
                    id: key,
                    date: existing.date,
                    providerID: existing.providerID,
                    modelId: existing.modelId,
                    variant: existing.variant,
                    inputTokens: existing.inputTokens + item.inputTokens,
                    outputTokens: existing.outputTokens + item.outputTokens,
                    cacheReadTokens: existing.cacheReadTokens + item.cacheReadTokens,
                    reasoningTokens: existing.reasoningTokens + item.reasoningTokens,
                    cacheWriteTokens: existing.cacheWriteTokens + item.cacheWriteTokens
                )
            } else {
                map[key] = item
            }
        }
        return map.values.sorted { $0.date < $1.date }
    }

    private static func mergePeriods(_ a: [TimePeriod], _ b: [TimePeriod]) -> [TimePeriod] {
        let combined = Dictionary((a + b).map { ("\($0.year)/\($0.month ?? "")", $0) }) { _, new in new }
        return combined.values.sorted { ($0.year, $0.month ?? "") > ($1.year, $1.month ?? "") }
    }

    private static func mergeDays(_ a: [String], _ b: [String]) -> [String] {
        Array(Set(a + b)).sorted()
    }

    /// 按当前时间模式填充缺失日（含模型集合保留）
    private func fill(_ data: [DailyModelUsage]) -> [DailyModelUsage] {
        let pricingRules = ModelPricingStore.load()
        let filtered = data.filter {
            ModelPricingStore.isEnabled(forModelId: $0.modelId, variant: $0.variant, providerID: $0.providerID, rules: pricingRules)
        }
        if isMonthlyMode, let year = selectedYear, let month = selectedMonth {
            if filterMode == .day, let day = selectedDay {
                let date = Self.dateFrom(year: year, month: month, day: day)
                return fillMissingDaysInRange(filtered, from: date, to: date)
            }
            return fillMissingDaysInRange(
                filtered,
                from: Self.dateFrom(year: year, month: month),
                to: Self.lastDayOf(year: year, month: month)
            )
        }
        if isCustomMode {
            return fillMissingDaysInRange(filtered, from: startDate, to: endDate)
        }
        return fillMissingDays(filtered, days: days)
    }

    private static func dateFrom(year: String, month: String) -> Date {
        let cal = Calendar.current
        return cal.date(from: DateComponents(year: Int(year), month: Int(month), day: 1)) ?? Date()
    }

    private static func dateFrom(year: String, month: String, day: String) -> Date {
        let cal = Calendar.current
        return cal.date(from: DateComponents(year: Int(year), month: Int(month), day: Int(day))) ?? Date()
    }

    private static func lastDayOf(year: String, month: String) -> Date {
        let cal = Calendar.current
        guard let first = cal.date(from: DateComponents(year: Int(year), month: Int(month), day: 1)),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: first),
              let last = cal.date(byAdding: .day, value: -1, to: nextMonth) else { return Date() }
        return last
    }

    private func fillMissingDaysInRange(_ data: [DailyModelUsage], from startDate: Date, to endDate: Date) -> [DailyModelUsage] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let end = cal.startOfDay(for: endDate)

        let allModels = Set(data.map { "\($0.providerID)\t\($0.modelId)\t\($0.variant)" })
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let lookup = Dictionary(uniqueKeysWithValues: data.map {
            ("\(df.string(from: $0.date))\t\($0.providerID)\t\($0.modelId)\t\($0.variant)", $0)
        })

        var result: [DailyModelUsage] = []
        var current = start
        while current <= end {
            let dateStr = df.string(from: current)
            for key in allModels {
                let parts = key.split(separator: "\t", maxSplits: 2)
                let providerID = String(parts[0])
                let modelId = parts.count > 1 ? String(parts[1]) : "unknown"
                let variant = parts.count > 2 ? String(parts[2]) : "default"
                let lookupKey = "\(dateStr)\t\(providerID)\t\(modelId)\t\(variant)"
                if let item = lookup[lookupKey] {
                    result.append(item)
                } else {
                    result.append(DailyModelUsage(
                        id: "\(dateStr)/\(providerID)/\(modelId)/\(variant)",
                        date: current,
                        providerID: providerID,
                        modelId: modelId,
                        variant: variant,
                        inputTokens: 0,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        reasoningTokens: 0,
                        cacheWriteTokens: 0
                    ))
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return result.sorted { $0.date < $1.date }
    }

    private func fillMissingDays(_ data: [DailyModelUsage], days: Int) -> [DailyModelUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return data }
        return fillMissingDaysInRange(data, from: startDate, to: today)
    }
}
