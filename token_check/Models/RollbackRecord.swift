import Foundation

struct RollbackRecord: Codable {
    var rolledBackInput: Int
    var rolledBackOutput: Int
    var rolledBackReasoning: Int
    var rolledBackCacheRead: Int
    var rolledBackCacheWrite: Int

    static let zero = RollbackRecord(
        rolledBackInput: 0,
        rolledBackOutput: 0,
        rolledBackReasoning: 0,
        rolledBackCacheRead: 0,
        rolledBackCacheWrite: 0
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

    static func + (lhs: RollbackRecord, rhs: RollbackRecord) -> RollbackRecord {
        RollbackRecord(
            rolledBackInput: lhs.rolledBackInput + rhs.rolledBackInput,
            rolledBackOutput: lhs.rolledBackOutput + rhs.rolledBackOutput,
            rolledBackReasoning: lhs.rolledBackReasoning + rhs.rolledBackReasoning,
            rolledBackCacheRead: lhs.rolledBackCacheRead + rhs.rolledBackCacheRead,
            rolledBackCacheWrite: lhs.rolledBackCacheWrite + rhs.rolledBackCacheWrite
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
}
