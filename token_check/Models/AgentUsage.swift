import Foundation

struct AgentUsage: Identifiable {
    let agentName: String
    let sessions: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let cost: Double

    var id: String { agentName }

    var linesPer1KTokens: Double {
        totalTokens > 0 ? Double(0) : 0
    }
}
