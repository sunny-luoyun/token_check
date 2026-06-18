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
        let key = "\(item.modelId)/\(item.variant)"
        let pricing = pricingLookup[key] ?? .defaults(modelId: item.modelId, variant: item.variant)
        switch metric {
        case .total:
            return Double(item.inputTokens) / 1_000_000 * pricing.inputMissPricePerMillion
                + Double(item.cacheReadTokens) / 1_000_000 * pricing.cacheHitPricePerMillion
                + Double(item.outputTokens) / 1_000_000 * pricing.outputPricePerMillion
        case .input:
            return Double(item.inputTokens) / 1_000_000 * pricing.inputMissPricePerMillion
        case .cacheHit:
            return Double(item.cacheReadTokens) / 1_000_000 * pricing.cacheHitPricePerMillion
        case .output:
            return Double(item.outputTokens) / 1_000_000 * pricing.outputPricePerMillion
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = try DatabaseService()
                if let db = service.db {
                    TokenDeltaTracker.shared.refresh(db: db)
                }
                let rbTotal: Int
                let data: [DailyModelUsage]
                if self.isCustomMode {
                    rbTotal = TokenDeltaTracker.shared.rollback(from: self.startDate, to: self.endDate).total
                    data = try service.fetchDailyUsageByModel(from: self.startDate, to: self.endDate)
                } else if self.isMonthlyMode {
                    rbTotal = TokenDeltaTracker.shared.rollback(year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay).total
                    data = try service.fetchDailyUsageByModel(year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay)
                } else {
                    rbTotal = TokenDeltaTracker.shared.rollback(days: self.days).total
                    data = try service.fetchDailyUsageByModel(days: self.days)
                }
                let periods = try service.fetchAvailablePeriods()
                let pricingRules = ModelPricingStore.load()

                let filteredData = data.filter {
                    ModelPricingStore.isEnabled(forModelId: $0.modelId, variant: $0.variant, rules: pricingRules)
                }

                var days: [String] = []
                if self.isMonthlyMode, let year = self.selectedYear, let month = self.selectedMonth {
                    days = try service.fetchAvailableDays(year: year, month: month)
                }

                let filledData = (self.isMonthlyMode || self.isCustomMode) ? filteredData : self.fillMissingDays(filteredData, days: self.days)

                DispatchQueue.main.async {
                    self.periods = periods
                    self.dailyData = filledData
                    self.availableDays = ["全部"] + days
                    self.rolledBackTotal = rbTotal
                    let availableModels = Set(filledData.map(\.displayName))
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

    func applyFilter() {
        load()
    }

    private func fillMissingDays(_ data: [DailyModelUsage], days: Int) -> [DailyModelUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return data }

        let allModels = Set(data.map { "\($0.modelId)\t\($0.variant)" })
        let lookup = Dictionary(uniqueKeysWithValues: data.map {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return ("\(df.string(from: $0.date))\t\($0.modelId)\t\($0.variant)", $0)
        })

        var result: [DailyModelUsage] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        for i in 0..<days {
            guard let date = cal.date(byAdding: .day, value: i, to: startDate) else { continue }
            let dateStr = df.string(from: date)
            for key in allModels {
                let parts = key.split(separator: "\t", maxSplits: 1)
                let modelId = String(parts[0])
                let variant = parts.count > 1 ? String(parts[1]) : "default"
                let lookupKey = "\(dateStr)\t\(modelId)\t\(variant)"
                if let item = lookup[lookupKey] {
                    result.append(item)
                } else {
                    result.append(DailyModelUsage(
                        id: "\(dateStr)/\(modelId)/\(variant)",
                        date: date,
                        modelId: modelId,
                        variant: variant,
                        totalTokens: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        cacheReadTokens: 0
                    ))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}
