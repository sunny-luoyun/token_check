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
    private var lastWidgetReload: Date = .distantPast

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
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            if let ds = DatabaseService.shared, let db = ds.db {
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

            let adjInput = result.map { $0.inputTokens + todayRb.rolledBackInput } ?? 0
            let adjOutput = result.map { $0.outputTokens + todayRb.rolledBackOutput } ?? 0
            let adjCacheRead = result.map { $0.cacheReadTokens + todayRb.rolledBackCacheRead } ?? 0
            let adjTotal = result.map { $0.totalTokens + todayRb.total } ?? 0

            // 主线程只更新 UI，不涉及任何跨进程调用
            DispatchQueue.main.async {
                self.hasRollback = hasRb
                self.rollbackTotal = todayRb.total
                self.adjustedInput = adjInput
                self.adjustedOutput = adjOutput
                self.adjustedCacheRead = adjCacheRead
                self.adjustedTotal = adjTotal
                if let result {
                    self.usage = result
                } else {
                    self.error = "无法读取数据库"
                }
                self.isLoading = false
                if apiKey.isEmpty {
                    self.deepseekBalance = nil
                    self.deepseekLoading = false
                }
            }

            // 跨进程操作（UserDefaults + WidgetCenter）在后台执行，绝不阻塞主线程
            guard let result else { return }
            let widgetUsage = TodayUsage(
                totalTokens: adjTotal,
                inputTokens: adjInput,
                outputTokens: adjOutput,
                cacheReadTokens: adjCacheRead,
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
            // 节流：每分钟最多 reload 一次 Widget
            let now = Date()
            guard now.timeIntervalSince(self.lastWidgetReload) >= 60 else { return }
            self.lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
