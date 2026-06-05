import Foundation

struct DailyModelUsage: Identifiable {
    let id: String
    let date: Date
    let modelId: String
    let variant: String
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int

    var displayName: String {
        variant == "default" || variant == "max" ? modelId : "\(modelId) (\(variant))"
    }
}
