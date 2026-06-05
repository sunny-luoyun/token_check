import Combine
import Foundation

class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""
    @Published var periods: [TimePeriod] = []
    @Published var selectedYear: String?
    @Published var selectedMonth: String?

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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = try DatabaseService()
                let periods = try service.fetchAvailablePeriods()
                let sessions = try service.fetchSessions(year: self.selectedYear, month: self.selectedMonth, limit: 200)
                DispatchQueue.main.async {
                    self.periods = periods
                    self.sessions = sessions
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
