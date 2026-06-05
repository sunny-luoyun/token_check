import Combine
import Foundation

class TokenViewModel: ObservableObject {
    @Published var totalTokens: Int = 0
    @Published var usage: TodayUsage?
    @Published var isLoading = false
    @Published var error: String?

    private let service = WidgetDataService()

    func refresh() {
        isLoading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = service.fetchTodayUsage()
            DispatchQueue.main.async {
                if let result {
                    self.totalTokens = result.totalTokens
                    self.usage = result
                } else {
                    self.error = "无法读取数据库"
                }
                self.isLoading = false
            }
        }
    }
}
