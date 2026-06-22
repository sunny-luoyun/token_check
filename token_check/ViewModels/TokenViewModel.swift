import Combine
import Foundation
import WidgetKit

class TokenViewModel: ObservableObject {
    @Published var usage: TodayUsage?
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasRollback = false
    @Published var rollbackTotal: Int = 0
    @Published var adjustedInput: Int = 0
    @Published var adjustedOutput: Int = 0
    @Published var adjustedCacheRead: Int = 0
    @Published var adjustedTotal: Int = 0
    @Published var deepseekBalance: String?
    @Published var deepseekLoading = false

    private let service = WidgetDataService()
    private var fileWatcherCancellable: AnyCancellable?

    init() {
        DatabaseFileWatcher.shared.startWatching()
        fileWatcherCancellable = DatabaseFileWatcher.shared.publisher
            .sink { [weak self] in
                self?.refresh(showLoading: false)
            }
    }

    func refresh(showLoading: Bool = true) {
        let apiKey = UserDefaults.standard.string(forKey: "deepseekApiKey") ?? ""
        if showLoading {
            isLoading = true
            deepseekLoading = !apiKey.isEmpty
        }
        error = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let ds = try? DatabaseService(), let db = ds.db {
                TokenDeltaTracker.shared.refresh(db: db)
            }
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            let todayKey = df.string(from: Date())
            let todayRb = TokenDeltaTracker.shared.dailyRollbacks[todayKey] ?? .zero
            let hasRb = todayRb.total > 0
            let result = service.fetchTodayUsage()

            if !apiKey.isEmpty {
                Task {
                    let balance = await DeepSeekBalanceService.shared.fetchBalance(apiKey: apiKey)
                    await MainActor.run {
                        self.deepseekBalance = balance
                        self.deepseekLoading = false
                    }
                }
            }

            DispatchQueue.main.async {
                self.hasRollback = hasRb
                self.rollbackTotal = todayRb.total
                if let result {
                    self.usage = result
                    self.adjustedInput = result.inputTokens + todayRb.rolledBackInput
                    self.adjustedOutput = result.outputTokens + todayRb.rolledBackOutput
                    self.adjustedCacheRead = result.cacheReadTokens + todayRb.rolledBackCacheRead
                    self.adjustedTotal = result.totalTokens + todayRb.total

                    let widgetUsage = TodayUsage(
                        totalTokens: self.adjustedTotal,
                        inputTokens: self.adjustedInput,
                        outputTokens: self.adjustedOutput,
                        cacheReadTokens: self.adjustedCacheRead,
                        sessionCount: result.sessionCount,
                        dailyTokens: result.dailyTokens,
                        todayCost: result.todayCost
                    )
                    if let data = try? JSONEncoder().encode(widgetUsage),
                       let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") {
                        defaults.set(data, forKey: "today_usage")
                    }
                    if let monthData = self.service.fetchMonthData(),
                       let encoded = try? JSONEncoder().encode(monthData),
                       let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") {
                        defaults.set(encoded, forKey: "monthly_heatmap")
                    }
                    if let yearlyData = self.service.fetchYearlyData(),
                       let encoded = try? JSONEncoder().encode(yearlyData),
                       let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") {
                        defaults.set(encoded, forKey: "yearly_heatmap")
                    }
                    WidgetCenter.shared.reloadAllTimelines()
                } else {
                    self.error = "无法读取数据库"
                }
                self.isLoading = false
                if apiKey.isEmpty {
                    self.deepseekBalance = nil
                    self.deepseekLoading = false
                }
            }
        }
    }
}
