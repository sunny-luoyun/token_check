import Combine
import Foundation

class CostViewModel: ObservableObject {
    @Published var summary: CostSummary?
    @Published var modelBreakdown: [ModelCostBreakdown] = []
    @Published var pricingDescription = ""
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
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasRollback = false
    @Published var rollbackTotal: Int = 0
    @Published var showRollback: Bool {
        didSet { defaults.set(showRollback, forKey: Self.showRollbackKey) }
    }
    @Published var dataSource: StatsDataSource {
        didSet { defaults.set(dataSource.rawValue, forKey: Self.dataSourceKey) }
    }
    /// DSH 数据完整度（L2 事件级 / L1 投影回退）
    @Published var dshLevel: DshDetailLevel = .full

    private var hasInitialized = false

    private let defaults = UserDefaults.standard
    private static let showRollbackKey = "cost_showRollback"
    private static let dataSourceKey = "cost_dataSource"

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

    private struct OpencodeCostData {
        let breakdown: [ModelCostBreakdown]
        let periods: [TimePeriod]
        let days: [String]
        let hasRollback: Bool
        let rollbackTotal: Int
        let pricingDescription: String
    }

    /// opencode 费用分解（含回滚调整；失败抛错）
    private func fetchOpencodeData() throws -> OpencodeCostData {
        if let ds = DatabaseService.shared, let db = ds.db {
            TokenDeltaTracker.shared.refresh(db: db)
        }
        guard let service = DatabaseService.shared else { throw DatabaseError.cannotOpen("") }
        let pricingRules = ModelPricingStore.load()
        let rb: RollbackRecord
        let modelRb: [String: TokenData]
        let breakdown: [ModelCostBreakdown]
        let periods = try service.fetchAvailablePeriods()
        let referenceDate: Date

        if filterMode == .range {
            referenceDate = endDate
            rb = TokenDeltaTracker.shared.rollback(from: startDate, to: endDate)
            modelRb = TokenDeltaTracker.shared.modelRollbacks(from: startDate, to: endDate)
            breakdown = try service.fetchModelCostBreakdown(
                from: startDate,
                to: endDate,
                pricingRules: pricingRules,
                referenceDate: referenceDate
            )
        } else {
            referenceDate = .now
            rb = TokenDeltaTracker.shared.rollback(year: selectedYear, month: selectedMonth, day: selectedDay)
            modelRb = TokenDeltaTracker.shared.modelRollbacks(year: selectedYear, month: selectedMonth, day: selectedDay)
            breakdown = try service.fetchModelCostBreakdown(
                year: selectedYear,
                month: selectedMonth,
                day: selectedDay,
                pricingRules: pricingRules,
                referenceDate: referenceDate
            )
        }

        let breakdownFiltered = breakdown
            .filter { $0.pricing.isEnabled }
            .sorted { $0.cacheMissTokens > $1.cacheMissTokens }

        let summary = CostSummary.from(breakdown: breakdownFiltered)
        let pricingDescription = Self.makePricingDescription(for: breakdownFiltered)

        let adjustedBreakdown: [ModelCostBreakdown] = breakdownFiltered.map { item in
            let rb = modelRb[item.id] ?? .zero
            let prices = item.pricing.price(at: referenceDate)
            return ModelCostBreakdown(
                id: item.id,
                providerID: item.providerID,
                modelId: item.modelId,
                variant: item.variant,
                sessions: item.sessions,
                cacheMissTokens: item.cacheMissTokens + rb.tokensInput,
                cacheHitTokens: item.cacheHitTokens + rb.tokensCacheRead,
                outputTokens: item.outputTokens + rb.tokensOutput,
                reasoningTokens: item.reasoningTokens + rb.tokensReasoning,
                pricing: item.pricing,
                resolvedInputPrice: prices.inputMiss,
                resolvedCacheHitPrice: prices.cacheHit,
                resolvedOutputPrice: prices.output,
                resolvedReasoningPrice: prices.reasoning,
                displayNameOverride: nil
            )
        }
        let useAdjusted = showRollback && rb.total > 0
        let finalBreakdown = useAdjusted ? adjustedBreakdown : breakdownFiltered

        var days: [String] = []
        if filterMode == .day, let year = selectedYear, let month = selectedMonth {
            days = try service.fetchAvailableDays(year: year, month: month)
        }

        return OpencodeCostData(
            breakdown: finalBreakdown,
            periods: periods,
            days: days,
            hasRollback: rb.total > 0,
            rollbackTotal: rb.total,
            pricingDescription: pricingDescription
        )
    }

    private struct DshCostData {
        let breakdown: [ModelCostBreakdown]
        let periods: [TimePeriod]
        let days: [String]
        let level: DshDetailLevel
    }

    /// DSH 费用分解（事件级；zstd 不可用时回退投影缓存）
    private func fetchDshData() -> DshCostData? {
        guard case .success(let dataSource) = DshService.shared.loadDetailedData() else {
            return nil
        }
        let filter: DshTimeFilter
        if filterMode == .range {
            filter = DshTimeFilter(from: startDate, to: endDate, year: nil, month: nil, day: nil)
        } else {
            filter = DshTimeFilter(from: nil, to: nil, year: selectedYear, month: selectedMonth, day: selectedDay)
        }
        let referenceDate: Date = filterMode == .range ? endDate : .now
        let breakdown = dataSource.modelCostBreakdown(filter, referenceDate: referenceDate)

        var days: [String] = []
        if filterMode == .day {
            days = dataSource.days(year: selectedYear, month: selectedMonth)
        }

        return DshCostData(
            breakdown: breakdown,
            periods: dataSource.periods(),
            days: days,
            level: dataSource.level
        )
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
                    self.summary = CostSummary.from(breakdown: data.breakdown)
                    self.modelBreakdown = data.breakdown
                    self.pricingDescription = data.pricingDescription
                    self.availableDays = ["全部"] + data.days
                    self.hasRollback = data.hasRollback
                    self.rollbackTotal = data.rollbackTotal
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
                let data = self.fetchDshData() ?? DshCostData(
                    breakdown: [], periods: dataSource.periods(), days: [], level: dataSource.level
                )
                DispatchQueue.main.async {
                    self.periods = data.periods
                    self.summary = CostSummary.from(breakdown: data.breakdown)
                    self.modelBreakdown = data.breakdown
                    self.pricingDescription = dataSource.isFull
                        ? "DSH 事件级统计（按模型分解，费用按模型价格规则估算）"
                        : "DSH 仅投影缓存（费用按默认模型估算；逐模型分解需 zstd 日志）"
                    self.availableDays = ["全部"] + data.days
                    self.hasRollback = false
                    self.rollbackTotal = 0
                    self.dshLevel = data.level
                    self.isLoading = false
                }
            case .missing:
                DispatchQueue.main.async {
                    self.summary = nil
                    self.modelBreakdown = []
                    self.periods = []
                    self.availableDays = []
                    self.error = "未检测到 DSH 数据（\(DshService.dshHomePath ?? "~/.dsh") 下无投影缓存）。\n请先通过 DeepSeek Harness 开始至少一个会话。"
                    self.isLoading = false
                }
            case .failure(let message):
                DispatchQueue.main.async {
                    self.summary = nil
                    self.modelBreakdown = []
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
            var ocData: OpencodeCostData?
            do {
                ocData = try self.fetchOpencodeData()
            } catch {
                ocError = error.localizedDescription
            }
            let dshData = self.fetchDshData()

            // 两个数据源都失败才报错；单个失败时用另一个
            if ocData == nil, dshData == nil {
                DispatchQueue.main.async {
                    self.error = ocError ?? "未检测到 DSH 数据（\(DshService.dshHomePath ?? "~/.dsh") 下无投影缓存）"
                    self.isLoading = false
                }
                return
            }

            let mergedBreakdown = Self.mergeBreakdowns(ocData?.breakdown ?? [], dshData?.breakdown ?? [])
            let mergedPeriods = Self.mergePeriods(ocData?.periods ?? [], dshData?.periods ?? [])
            let mergedDays = Self.mergeDays(ocData?.days ?? [], dshData?.days ?? [])

            DispatchQueue.main.async {
                self.periods = mergedPeriods
                self.summary = CostSummary.from(breakdown: mergedBreakdown)
                self.modelBreakdown = mergedBreakdown
                if let ocData {
                    self.hasRollback = ocData.hasRollback
                    self.rollbackTotal = ocData.rollbackTotal
                } else {
                    self.hasRollback = false
                    self.rollbackTotal = 0
                }
                if let ocData, ocData.breakdown.isEmpty {
                    self.pricingDescription = "仅 DSH 数据（opencode 不可用：\(ocError ?? "")）"
                } else if ocData == nil {
                    self.pricingDescription = "仅 DSH 数据（opencode 数据库不可用）"
                } else {
                    self.pricingDescription = "opencode + DSH 合并统计（DSH 部分按模型价格规则估算）"
                }
                self.availableDays = ["全部"] + mergedDays
                self.dshLevel = dshData?.level ?? .missing
                self.isLoading = false
            }
        }
    }

    private static func mergeBreakdowns(_ a: [ModelCostBreakdown], _ b: [ModelCostBreakdown]) -> [ModelCostBreakdown] {
        var map: [String: ModelCostBreakdown] = [:]
        for item in a + b {
            if let existing = map[item.id] {
                map[item.id] = ModelCostBreakdown(
                    id: existing.id,
                    providerID: existing.providerID,
                    modelId: existing.modelId,
                    variant: existing.variant,
                    sessions: existing.sessions + item.sessions,
                    cacheMissTokens: existing.cacheMissTokens + item.cacheMissTokens,
                    cacheHitTokens: existing.cacheHitTokens + item.cacheHitTokens,
                    outputTokens: existing.outputTokens + item.outputTokens,
                    reasoningTokens: existing.reasoningTokens + item.reasoningTokens,
                    pricing: existing.pricing,
                    resolvedInputPrice: existing.resolvedInputPrice,
                    resolvedCacheHitPrice: existing.resolvedCacheHitPrice,
                    resolvedOutputPrice: existing.resolvedOutputPrice,
                    resolvedReasoningPrice: existing.resolvedReasoningPrice,
                    displayNameOverride: existing.displayNameOverride ?? item.displayNameOverride
                )
            } else {
                map[item.id] = item
            }
        }
        return map.values.sorted { $0.cacheMissTokens > $1.cacheMissTokens }
    }

    private static func mergePeriods(_ a: [TimePeriod], _ b: [TimePeriod]) -> [TimePeriod] {
        let combined = Dictionary((a + b).map { ("\($0.year)/\($0.month ?? "")", $0) }) { _, new in new }
        return combined.values.sorted { ($0.year, $0.month ?? "") > ($1.year, $1.month ?? "") }
    }

    private static func mergeDays(_ a: [String], _ b: [String]) -> [String] {
        Array(Set(a + b)).sorted()
    }

    private static func makePricingDescription(for breakdown: [ModelCostBreakdown]) -> String {
        let customizedCount = Set(
            breakdown
                .filter { !$0.pricing.usesDefaultPricing }
                .map(\.pricing.pricingKey)
        ).count

        if customizedCount == 0 {
            return "输入（未命中） $0.14/百万token · 缓存命中 $0.0028/百万token · 输出 $0.28/百万token"
        }

        return "按设置中的模型单价计算（已配置 \(customizedCount) 个模型）"
    }
}
