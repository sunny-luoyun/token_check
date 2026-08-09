import Foundation

struct SummaryData: Codable, Equatable {
    var additions: Int
    var deletions: Int
    var files: Int

    static let zero = SummaryData(additions: 0, deletions: 0, files: 0)

    var total: Int { additions + deletions + files }

    static func + (lhs: SummaryData, rhs: SummaryData) -> SummaryData {
        SummaryData(
            additions: lhs.additions + rhs.additions,
            deletions: lhs.deletions + rhs.deletions,
            files: lhs.files + rhs.files
        )
    }

    static func += (lhs: inout SummaryData, rhs: SummaryData) {
        lhs = lhs + rhs
    }

    static func - (lhs: SummaryData, rhs: SummaryData) -> SummaryData {
        SummaryData(
            additions: lhs.additions - rhs.additions,
            deletions: lhs.deletions - rhs.deletions,
            files: lhs.files - rhs.files
        )
    }
}
