import Foundation

struct ModelUsage: Identifiable {
    let id: String
    let providerID: String
    let modelId: String
    let variant: String
    let sessions: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let cost: Double

    var displayName: String {
        buildDisplayName()
    }

    private func buildDisplayName() -> String {
        let name = variant == "default" || variant == "max" ? modelId : "\(modelId) (\(variant))"
        if providerID == "opencode" { return name }
        return "[\(providerID)] \(name)"
    }
}
