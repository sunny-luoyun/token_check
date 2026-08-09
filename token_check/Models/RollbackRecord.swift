import Foundation

struct RollbackRecord: Codable {
    var rolledBackInput: Int
    var rolledBackOutput: Int
    var rolledBackReasoning: Int
    var rolledBackCacheRead: Int
    var rolledBackCacheWrite: Int
    var rolledBackCost: Double
    var rolledBackAdditions: Int
    var rolledBackDeletions: Int
    var rolledBackFiles: Int

    static let zero = RollbackRecord(
        rolledBackInput: 0,
        rolledBackOutput: 0,
        rolledBackReasoning: 0,
        rolledBackCacheRead: 0,
        rolledBackCacheWrite: 0,
        rolledBackCost: 0,
        rolledBackAdditions: 0,
        rolledBackDeletions: 0,
        rolledBackFiles: 0
    )

    var total: Int {
        rolledBackInput + rolledBackOutput + rolledBackReasoning + rolledBackCacheRead + rolledBackCacheWrite
    }

    var asTokenData: TokenData {
        TokenData(
            tokensInput: rolledBackInput,
            tokensOutput: rolledBackOutput,
            tokensReasoning: rolledBackReasoning,
            tokensCacheRead: rolledBackCacheRead,
            tokensCacheWrite: rolledBackCacheWrite
        )
    }

    var asSummaryData: SummaryData {
        SummaryData(
            additions: rolledBackAdditions,
            deletions: rolledBackDeletions,
            files: rolledBackFiles
        )
    }

    init(
        rolledBackInput: Int, rolledBackOutput: Int, rolledBackReasoning: Int,
        rolledBackCacheRead: Int, rolledBackCacheWrite: Int,
        rolledBackCost: Double, rolledBackAdditions: Int, rolledBackDeletions: Int, rolledBackFiles: Int
    ) {
        self.rolledBackInput = rolledBackInput
        self.rolledBackOutput = rolledBackOutput
        self.rolledBackReasoning = rolledBackReasoning
        self.rolledBackCacheRead = rolledBackCacheRead
        self.rolledBackCacheWrite = rolledBackCacheWrite
        self.rolledBackCost = rolledBackCost
        self.rolledBackAdditions = rolledBackAdditions
        self.rolledBackDeletions = rolledBackDeletions
        self.rolledBackFiles = rolledBackFiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rolledBackInput = try c.decode(Int.self, forKey: .rolledBackInput)
        rolledBackOutput = try c.decode(Int.self, forKey: .rolledBackOutput)
        rolledBackReasoning = try c.decode(Int.self, forKey: .rolledBackReasoning)
        rolledBackCacheRead = try c.decode(Int.self, forKey: .rolledBackCacheRead)
        rolledBackCacheWrite = try c.decode(Int.self, forKey: .rolledBackCacheWrite)
        rolledBackCost = try c.decodeIfPresent(Double.self, forKey: .rolledBackCost) ?? 0
        rolledBackAdditions = try c.decodeIfPresent(Int.self, forKey: .rolledBackAdditions) ?? 0
        rolledBackDeletions = try c.decodeIfPresent(Int.self, forKey: .rolledBackDeletions) ?? 0
        rolledBackFiles = try c.decodeIfPresent(Int.self, forKey: .rolledBackFiles) ?? 0
    }

    static func + (lhs: RollbackRecord, rhs: RollbackRecord) -> RollbackRecord {
        RollbackRecord(
            rolledBackInput: lhs.rolledBackInput + rhs.rolledBackInput,
            rolledBackOutput: lhs.rolledBackOutput + rhs.rolledBackOutput,
            rolledBackReasoning: lhs.rolledBackReasoning + rhs.rolledBackReasoning,
            rolledBackCacheRead: lhs.rolledBackCacheRead + rhs.rolledBackCacheRead,
            rolledBackCacheWrite: lhs.rolledBackCacheWrite + rhs.rolledBackCacheWrite,
            rolledBackCost: lhs.rolledBackCost + rhs.rolledBackCost,
            rolledBackAdditions: lhs.rolledBackAdditions + rhs.rolledBackAdditions,
            rolledBackDeletions: lhs.rolledBackDeletions + rhs.rolledBackDeletions,
            rolledBackFiles: lhs.rolledBackFiles + rhs.rolledBackFiles
        )
    }

    static func += (lhs: inout RollbackRecord, rhs: RollbackRecord) {
        lhs = lhs + rhs
    }

    static func += (lhs: inout RollbackRecord, rhs: TokenData) {
        lhs.rolledBackInput += rhs.tokensInput
        lhs.rolledBackOutput += rhs.tokensOutput
        lhs.rolledBackReasoning += rhs.tokensReasoning
        lhs.rolledBackCacheRead += rhs.tokensCacheRead
        lhs.rolledBackCacheWrite += rhs.tokensCacheWrite
    }

    static func += (lhs: inout RollbackRecord, rhs: SummaryData) {
        lhs.rolledBackAdditions += rhs.additions
        lhs.rolledBackDeletions += rhs.deletions
        lhs.rolledBackFiles += rhs.files
    }

    static func += (lhs: inout RollbackRecord, cost: Double) {
        lhs.rolledBackCost += cost
    }
}
