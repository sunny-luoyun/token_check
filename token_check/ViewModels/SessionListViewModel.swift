import Combine
import Foundation

class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""
    @Published var sessionRollbacks: [String: TokenData] = [:]
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
    @Published var showRollback: Bool {
        didSet { defaults.set(showRollback, forKey: Self.showRollbackKey) }
    }

    var hasSessionRollback: Bool {
        sessionRollbacks.values.contains { $0.total > 0 }
    }

    private let defaults = UserDefaults.standard
    private static let showRollbackKey = "session_showRollback"

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

        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            do {
                guard let service = DatabaseService.shared else { throw DatabaseError.cannotOpen("") }
                let rb = TokenDeltaTracker.shared.sessionRollbacks
                let periods = try service.fetchAvailablePeriods()
                let sessions: [Session]
                if self.filterMode == .range {
                    sessions = try service.fetchSessions(from: self.startDate, to: self.endDate, limit: 200)
                } else {
                    sessions = try service.fetchSessions(year: self.selectedYear, month: self.selectedMonth, day: self.selectedDay, limit: 200)
                }

                var days: [String] = []
                if self.filterMode == .day, let year = self.selectedYear, let month = self.selectedMonth {
                    days = try service.fetchAvailableDays(year: year, month: month)
                }

                DispatchQueue.main.async {
                    self.periods = periods
                    self.sessions = sessions
                    self.availableDays = ["全部"] + days
                    self.sessionRollbacks = rb
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
