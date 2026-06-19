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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = try DatabaseService()
                let periods = try service.fetchAvailablePeriods()

                let agents = try service.fetchAgentUsage(
                    year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay,
                    from: self.filterMode == .range ? self.startDate : nil,
                    to: self.filterMode == .range ? self.endDate : nil
                )
                let projects = try service.fetchProjectUsage(
                    year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay,
                    from: self.filterMode == .range ? self.startDate : nil,
                    to: self.filterMode == .range ? self.endDate : nil
                )
                let effSummary = try service.fetchEfficiencySummary(
                    year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay,
                    from: self.filterMode == .range ? self.startDate : nil,
                    to: self.filterMode == .range ? self.endDate : nil
                )
                let effDetails = try service.fetchEfficiencyDetail(
                    year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay,
                    from: self.filterMode == .range ? self.startDate : nil,
                    to: self.filterMode == .range ? self.endDate : nil
                )

                var days: [String] = []
                if self.filterMode == .day, let year = self.selectedYear, let month = self.selectedMonth {
                    days = try service.fetchAvailableDays(year: year, month: month)
                }

                DispatchQueue.main.async {
                    self.availablePeriods = periods
                    self.agentUsage = agents
                    self.projectUsage = projects
                    self.efficiencySummary = effSummary
                    self.efficiencyDetails = effDetails
                    self.availableDays = ["全部"] + days
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
}
