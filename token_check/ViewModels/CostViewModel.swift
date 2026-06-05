import Combine
import Foundation

class CostViewModel: ObservableObject {
    @Published var summary: CostSummary?
    @Published var modelBreakdown: [ModelCostBreakdown] = []
    @Published var periods: [TimePeriod] = []
    @Published var selectedYear: String?
    @Published var selectedMonth: String?
    @Published var isLoading = false
    @Published var error: String?

    var availableYears: [String] {
        let years = Set(periods.map(\.year))
        return ["全部"] + years.sorted(by: >)
    }

    var availableMonths: [String] {
        guard let year = selectedYear else { return [] }
        let months = periods.filter { $0.year == year }.compactMap { $0.month }
        return ["全部"] + months.sorted()
    }

    private var lastLoad: (years: [String]?, months: [String]?)?
    private var needsReload = true

    func load() {
        guard needsReload || periods.isEmpty else { return }
        isLoading = true
        error = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = try DatabaseService()
                let periods = try service.fetchAvailablePeriods()
                let summary = try service.fetchCostSummary(year: self.selectedYear, month: self.selectedMonth)
                let breakdown = try service.fetchModelCostBreakdown(year: self.selectedYear, month: self.selectedMonth)

                DispatchQueue.main.async {
                    self.periods = periods
                    self.summary = summary
                    self.modelBreakdown = breakdown
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
