import Foundation

struct DailyUsage: Identifiable {
    let id: String
    let date: Date
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
}
