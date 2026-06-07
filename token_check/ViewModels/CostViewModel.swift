import Combine
import Foundation

class CostViewModel: ObservableObject {
    @Published var summary: CostSummary?
    @Published var modelBreakdown: [ModelCostBreakdown] = []
    @Published var pricingDescription = ""
    @Published var periods: [TimePeriod] = []
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

    private let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") ?? .standard
    private static let showRollbackKey = "cost_showRollback"

    init() {
        showRollback = (UserDefaults(suiteName: "group.com.luoyun.tokencheck") ?? .standard).object(forKey: Self.showRollbackKey) as? Bool ?? true
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = try DatabaseService()
                if let db = service.db {
                    TokenDeltaTracker.shared.refresh(db: db)
                }
                let rb = TokenDeltaTracker.shared.rollback(year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay)
                let periods = try service.fetchAvailablePeriods()
                let pricingRules = ModelPricingStore.load()
                let breakdown = try service.fetchModelCostBreakdown(
                    year: self.selectedYear,
                    month: self.selectedMonth,
                    day: self.selectedDay,
                    pricingRules: pricingRules
                )
                let summary = CostSummary.from(breakdown: breakdown)
                let pricingDescription = Self.makePricingDescription(for: breakdown)

                let modelRb = TokenDeltaTracker.shared.modelRollbacks(year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay)
                let adjustedBreakdown: [ModelCostBreakdown] = breakdown.map { item in
                    let rb = modelRb[item.id] ?? .zero
                    return ModelCostBreakdown(
                        id: item.id,
                        modelId: item.modelId,
                        variant: item.variant,
                        sessions: item.sessions,
                        cacheMissTokens: item.cacheMissTokens + rb.tokensInput,
                        cacheHitTokens: item.cacheHitTokens + rb.tokensCacheRead,
                        outputTokens: item.outputTokens + rb.tokensOutput,
                        reasoningTokens: item.reasoningTokens + rb.tokensReasoning,
                        pricing: item.pricing
                    )
                }
                let useAdjusted = self.showRollback && rb.total > 0
                let finalBreakdown = useAdjusted ? adjustedBreakdown : breakdown
                let finalSummary = useAdjusted ? CostSummary.from(breakdown: adjustedBreakdown) : summary

                var days: [String] = []
                if let year = self.selectedYear, let month = self.selectedMonth {
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
            return "输入（未命中） ¥1/百万token · 缓存命中 ¥0.02/百万token · 输出 ¥2/百万token"
        }

        return "按设置中的模型单价计算（已配置 \(customizedCount) 个模型）"
    }
}
