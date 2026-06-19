import Foundation

struct ProjectUsage: Identifiable {
    let projectId: String
    let projectName: String
    let worktree: String
    let sessions: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let cost: Double

    var id: String { projectId }

    var displayName: String {
        if !projectName.isEmpty { return projectName }
        if worktree == "/" { return "默认项目" }
        return (worktree as NSString).lastPathComponent
    }
}
