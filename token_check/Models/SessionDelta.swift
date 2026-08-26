import Foundation

struct SessionDelta: Codable, Equatable {
    var tokens: TokenData
    var cost: Double
    var summary: SummaryData
    var lastUpdated: Int64

    static let zero = SessionDelta(tokens: .zero, cost: 0, summary: .zero, lastUpdated: 0)

    var totalTokens: Int { tokens.total }

    static func + (lhs: SessionDelta, rhs: SessionDelta) -> SessionDelta {
        SessionDelta(
            tokens: lhs.tokens + rhs.tokens,
            cost: lhs.cost + rhs.cost,
            summary: lhs.summary + rhs.summary,
            lastUpdated: max(lhs.lastUpdated, rhs.lastUpdated)
        )
    }

    static func += (lhs: inout SessionDelta, rhs: SessionDelta) {
        lhs = lhs + rhs
    }

    static func - (lhs: SessionDelta, rhs: SessionDelta) -> SessionDelta {
        SessionDelta(
            tokens: lhs.tokens - rhs.tokens,
            cost: lhs.cost - rhs.cost,
            summary: lhs.summary - rhs.summary,
            lastUpdated: lhs.lastUpdated
        )
    }
}
