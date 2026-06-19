import Foundation

struct ProductivitySummary {
    let totalAdditions: Int
    let totalDeletions: Int
    let totalFiles: Int
    let sessionsWithChanges: Int
    let totalTokens: Int

    var avgLinesPer1KTokens: Double {
        totalTokens > 0
            ? Double(totalAdditions + totalDeletions) / Double(totalTokens) * 1000
            : 0
    }

    var netLines: Int {
        totalAdditions - totalDeletions
    }
}

struct SessionEfficiency: Identifiable {
    let id: String
    let title: String
    let modelId: String
    let agent: String
    let additions: Int
    let deletions: Int
    let files: Int
    let totalTokens: Int

    var tokensPerLine: Double {
        let changes = additions + deletions
        return changes > 0 ? Double(totalTokens) / Double(changes) : 0
    }

    var linesPer1KTokens: Double {
        totalTokens > 0
            ? Double(additions + deletions) / Double(totalTokens) * 1000
            : 0
    }
}
