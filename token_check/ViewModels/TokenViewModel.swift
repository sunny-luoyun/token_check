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

    private let service = WidgetDataService()

    func refresh() {
        isLoading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let ds = try? DatabaseService(), let db = ds.db {
                TokenDeltaTracker.shared.refresh(db: db)
            }
            let rb = TokenDeltaTracker.shared.rollbackRecord
            let hasRb = rb.total > 0
            let result = service.fetchTodayUsage()
            DispatchQueue.main.async {
                self.hasRollback = hasRb
                self.rollbackTotal = rb.total
                if let result {
                    self.usage = result
                    self.adjustedInput = result.inputTokens + rb.rolledBackInput
                    self.adjustedOutput = result.outputTokens + rb.rolledBackOutput
                    self.adjustedCacheRead = result.cacheReadTokens + rb.rolledBackCacheRead
                    self.adjustedTotal = result.totalTokens + rb.total
                } else {
                    self.error = "无法读取数据库"
                }
                self.isLoading = false
            }
        }
    }
}
