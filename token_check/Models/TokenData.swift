import Foundation

struct TokenData: Codable, Equatable {
    var tokensInput: Int
    var tokensOutput: Int
    var tokensReasoning: Int
    var tokensCacheRead: Int
    var tokensCacheWrite: Int

    static let zero = TokenData(
        tokensInput: 0,
        tokensOutput: 0,
        tokensReasoning: 0,
        tokensCacheRead: 0,
        tokensCacheWrite: 0
    )

    var total: Int {
        tokensInput + tokensOutput + tokensReasoning + tokensCacheRead + tokensCacheWrite
    }

    static func + (lhs: TokenData, rhs: TokenData) -> TokenData {
        TokenData(
            tokensInput: lhs.tokensInput + rhs.tokensInput,
            tokensOutput: lhs.tokensOutput + rhs.tokensOutput,
            tokensReasoning: lhs.tokensReasoning + rhs.tokensReasoning,
            tokensCacheRead: lhs.tokensCacheRead + rhs.tokensCacheRead,
            tokensCacheWrite: lhs.tokensCacheWrite + rhs.tokensCacheWrite
        )
    }

    static func - (lhs: TokenData, rhs: TokenData) -> TokenData {
        TokenData(
            tokensInput: lhs.tokensInput - rhs.tokensInput,
            tokensOutput: lhs.tokensOutput - rhs.tokensOutput,
            tokensReasoning: lhs.tokensReasoning - rhs.tokensReasoning,
            tokensCacheRead: lhs.tokensCacheRead - rhs.tokensCacheRead,
            tokensCacheWrite: lhs.tokensCacheWrite - rhs.tokensCacheWrite
        )
    }
}
