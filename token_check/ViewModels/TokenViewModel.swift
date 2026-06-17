import Combine
import Foundation

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
                self?.refresh()
            }
    }

    func refresh() {
        isLoading = true
        error = nil
        let apiKey = UserDefaults.standard.string(forKey: "deepseekApiKey") ?? ""
        deepseekLoading = !apiKey.isEmpty
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
