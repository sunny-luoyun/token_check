import Combine
import Foundation

class CostViewModel: ObservableObject {
    @Published var summary: CostSummary?
    @Published var modelBreakdown: [ModelCostBreakdown] = []
    @Published var pricingDescription = ""
    @Published var periods: [TimePeriod] = []
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
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasRollback = false
    @Published var rollbackTotal: Int = 0
    @Published var showRollback: Bool {
        didSet { defaults.set(showRollback, forKey: Self.showRollbackKey) }
    }

    private let defaults = UserDefaults.standard
    private static let showRollbackKey = "cost_showRollback"

    init() {
        showRollback = defaults.object(forKey: Self.showRollbackKey) as? Bool ?? true
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

        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            if let ds = DatabaseService.shared, let db = ds.db {
                TokenDeltaTracker.shared.refresh(db: db)
            }
            do {
                guard let service = DatabaseService.shared else { throw DatabaseError.cannotOpen("") }
                let pricingRules = ModelPricingStore.load()
                let rb: RollbackRecord
                let modelRb: [String: TokenData]
                let breakdown: [ModelCostBreakdown]
                let periods = try service.fetchAvailablePeriods()
                let referenceDate: Date

                if self.filterMode == .range {
                    referenceDate = self.endDate
                    rb = TokenDeltaTracker.shared.rollback(from: self.startDate, to: self.endDate)
                    modelRb = TokenDeltaTracker.shared.modelRollbacks(from: self.startDate, to: self.endDate)
                    breakdown = try service.fetchModelCostBreakdown(
                        from: self.startDate,
                        to: self.endDate,
                        pricingRules: pricingRules,
                        referenceDate: referenceDate
                    )
                } else {
                    referenceDate = .now
                    rb = TokenDeltaTracker.shared.rollback(year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay)
                    modelRb = TokenDeltaTracker.shared.modelRollbacks(year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay)
                    breakdown = try service.fetchModelCostBreakdown(
                        year: self.selectedYear,
                        month: self.selectedMonth,
                        day: self.selectedDay,
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
                        resolvedReasoningPrice: prices.reasoning
                    )
                }
                let useAdjusted = self.showRollback && rb.total > 0
                let finalBreakdown = useAdjusted ? adjustedBreakdown : breakdownFiltered
                let finalSummary = useAdjusted ? CostSummary.from(breakdown: adjustedBreakdown) : summary

                var days: [String] = []
                if self.filterMode == .day, let year = self.selectedYear, let month = self.selectedMonth {
                    days = try service.fetchAvailableDays(year: year, month: month)
                }

                DispatchQueue.main.async {
                    self.periods = periods
                    self.summary = finalSummary
                    self.modelBreakdown = finalBreakdown
                    self.pricingDescription = pricingDescription
                    self.availableDays = ["全部"] + days
                    self.hasRollback = rb.total > 0
                    self.rollbackTotal = rb.total
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

    func applyFilter() {
        load()
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
