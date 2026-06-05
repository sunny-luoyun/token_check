import Combine
import Foundation

class DailyTrendViewModel: ObservableObject {
    enum TimeMode: String, CaseIterable {
        case last7 = "7天"
        case last14 = "14天"
        case last30 = "30天"
        case last90 = "90天"
        case monthly = "按月"
    }

    @Published var timeMode: TimeMode = .last30
    @Published var selectedYear: String?
    @Published var selectedMonth: String?
    @Published var periods: [TimePeriod] = []
    @Published var dailyData: [DailyModelUsage] = []
    @Published var selectedModels: Set<String> = []
    @Published var isLoading = false
    @Published var error: String?

    var days: Int {
        switch timeMode {
        case .last7: return 7
        case .last14: return 14
        case .last30: return 30
        case .last90: return 90
        case .monthly: return 0
        }
    }

    var isMonthlyMode: Bool { timeMode == .monthly }

    var availableModels: [String] {
        Array(Set(dailyData.map(\.displayName))).sorted()
    }

    var filteredData: [DailyModelUsage] {
        if selectedModels.isEmpty {
            return dailyData
        }
        return dailyData.filter { selectedModels.contains($0.displayName) }
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

    private var needsReload = true

    func load() {
        guard needsReload else { return }
        isLoading = true
        error = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = try DatabaseService()
                let periods = try service.fetchAvailablePeriods()
                let data: [DailyModelUsage]
                if self.isMonthlyMode {
                    data = try service.fetchDailyUsageByModel(year: self.selectedYear, month: self.selectedMonth)
                } else {
                    data = try service.fetchDailyUsageByModel(days: self.days)
                }

                DispatchQueue.main.async {
                    self.periods = periods
                    self.dailyData = data
                    if self.selectedModels.isEmpty {
                        self.selectedModels = Set(data.map(\.displayName))
                    }
                    self.isLoading = false
                    self.needsReload = false
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
        needsReload = true
        load()
    }
}
