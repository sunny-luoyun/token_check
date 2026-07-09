import Foundation

struct DailyModelUsage: Identifiable {
    let id: String
    let date: Date
    let providerID: String
    let modelId: String
    let variant: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let cacheWriteTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens + cacheWriteTokens
    }

    var displayName: String {
        let name = variant == "default" || variant == "max" ? modelId : "\(modelId) (\(variant))"
        if providerID == "opencode" { return name }
        return "[\(providerID)] \(name)"
    }

    var modelKey: String {
        "\(providerID)/\(modelId)/\(variant)"
    }
}
