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
                + Double(item.reasoningTokens) / 1_000_000 * pricing.reasoningPricePerMillion
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
                let cal = Calendar.current
                let rbTotal: Int
                var data: [DailyModelUsage]
                var queryStart: Date?
                var queryEnd: Date?
                if self.isCustomMode {
                    queryStart = self.startDate
                    queryEnd = self.endDate
                    rbTotal = TokenDeltaTracker.shared.rollback(from: self.startDate, to: self.endDate).total
                    data = TokenDeltaTracker.shared.dailyModelUsage(from: self.startDate, to: self.endDate)
                } else if self.isMonthlyMode {
                    if let year = self.selectedYear, let month = self.selectedMonth {
                        if self.filterMode == .day, let day = self.selectedDay {
                            let date = Self.dateFrom(year: year, month: month, day: day)
                            queryStart = date
                            queryEnd = date
                            rbTotal = TokenDeltaTracker.shared.rollback(year: year, month: month, day: day).total
                            data = TokenDeltaTracker.shared.dailyModelUsage(from: date, to: date)
                        } else {
                            queryStart = Self.dateFrom(year: year, month: month)
                            queryEnd = Self.lastDayOf(year: year, month: month)
                            rbTotal = TokenDeltaTracker.shared.rollback(year: year, month: month, day: nil).total
                            data = TokenDeltaTracker.shared.dailyModelUsage(from: queryStart!, to: queryEnd!)
                        }
                    } else {
                        rbTotal = 0
                        data = []
                    }
                } else {
                    let today = cal.startOfDay(for: Date())
                    queryEnd = today
                    queryStart = cal.date(byAdding: .day, value: -(self.days - 1), to: today)
                    rbTotal = TokenDeltaTracker.shared.rollback(days: self.days).total
                    if let startDate = queryStart {
                        data = TokenDeltaTracker.shared.dailyModelUsage(from: startDate, to: today)
                    } else {
                        data = []
                    }
                }

                // 补充 session 表数据，填补 event 表可能缺失的历史记录
                if let qs = queryStart, let qe = queryEnd {
                    let sessionData = try service.fetchDailyUsageByModel(from: qs, to: qe)
                    data = self.mergeDailyUsage(eventData: data, sessionData: sessionData)
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

                let filledData: [DailyModelUsage]
                if self.isMonthlyMode, let year = self.selectedYear, let month = self.selectedMonth {
                    if self.filterMode == .day, let day = self.selectedDay {
                        let date = Self.dateFrom(year: year, month: month, day: day)
                        filledData = self.fillMissingDaysInRange(filteredData, from: date, to: date)
                    } else {
                        let start = Self.dateFrom(year: year, month: month)
                        let end = Self.lastDayOf(year: year, month: month)
                        filledData = self.fillMissingDaysInRange(filteredData, from: start, to: end)
                    }
                } else if self.isCustomMode {
                    filledData = self.fillMissingDaysInRange(filteredData, from: self.startDate, to: self.endDate)
                } else {
                    filledData = self.fillMissingDays(filteredData, days: self.days)
                }

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

    func applyFilter() {
        load()
    }

    private func mergeDailyUsage(eventData: [DailyModelUsage], sessionData: [DailyModelUsage]) -> [DailyModelUsage] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var resultMap: [String: DailyModelUsage] = [:]

        for item in sessionData {
            let key = "\(df.string(from: item.date))\t\(item.modelId)\t\(item.variant)"
            resultMap[key] = item
        }

        for item in eventData {
            let key = "\(df.string(from: item.date))\t\(item.modelId)\t\(item.variant)"
            if resultMap[key] == nil {
                resultMap[key] = item
            }
        }

        return Array(resultMap.values)
    }

    private func fillMissingDaysInRange(_ data: [DailyModelUsage], from startDate: Date, to endDate: Date) -> [DailyModelUsage] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let end = cal.startOfDay(for: endDate)

        let allModels = Set(data.map { "\($0.modelId)\t\($0.variant)" })
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let lookup = Dictionary(uniqueKeysWithValues: data.map {
            ("\(df.string(from: $0.date))\t\($0.modelId)\t\($0.variant)", $0)
        })

        var result: [DailyModelUsage] = []
        var current = start
        while current <= end {
            let dateStr = df.string(from: current)
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
                        date: current,
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
