import Foundation

struct ModelCostBreakdown: Identifiable {
    let id: String
    let modelId: String
    let variant: String
    let sessions: Int
    let cacheMissTokens: Int
    let cacheHitTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let pricing: ModelPricingRule

    var displayName: String {
        variant == "default" || variant == "max" ? modelId : "\(modelId) (\(variant))"
    }

    var missCost: Double {
        Double(cacheMissTokens) / 1_000_000 * pricing.inputMissPricePerMillion
    }

    var hitCost: Double {
        Double(cacheHitTokens) / 1_000_000 * pricing.cacheHitPricePerMillion
    }

    var outputCost: Double {
        Double(outputTokens) / 1_000_000 * pricing.outputPricePerMillion
    }

    var totalCost: Double {
        missCost + hitCost + outputCost
    }
}

struct CostSummary {
    let totalMissTokens: Int
    let totalHitTokens: Int
    let totalOutputTokens: Int
    let totalReasoningTokens: Int
    let sessionCount: Int
    let missCost: Double
    let hitCost: Double
    let outputCost: Double

    var totalCost: Double {
        missCost + hitCost + outputCost
    }

    static func from(breakdown: [ModelCostBreakdown]) -> CostSummary {
        CostSummary(
            totalMissTokens: breakdown.reduce(0) { $0 + $1.cacheMissTokens },
            totalHitTokens: breakdown.reduce(0) { $0 + $1.cacheHitTokens },
            totalOutputTokens: breakdown.reduce(0) { $0 + $1.outputTokens },
            totalReasoningTokens: breakdown.reduce(0) { $0 + $1.reasoningTokens },
            sessionCount: breakdown.reduce(0) { $0 + $1.sessions },
            missCost: breakdown.reduce(0) { $0 + $1.missCost },
            hitCost: breakdown.reduce(0) { $0 + $1.hitCost },
            outputCost: breakdown.reduce(0) { $0 + $1.outputCost }
        )
    }
}

struct TimePeriod: Identifiable, Hashable {
    let year: String
    let month: String?

    var id: String { year + (month.map { "-\($0)" } ?? "") }
    var displayName: String {
        if let month {
            let monthNames = ["", "1月", "2月", "3月", "4月", "5月", "6月",
                              "7月", "8月", "9月", "10月", "11月", "12月"]
            let m = Int(month) ?? 0
            return "\(year)年 \(m > 0 && m <= 12 ? monthNames[m] : "\(month)月")"
        }
        return "\(year)年"
    }
}

enum TimeFilter: Hashable {
    case all
    case year(String)
    case yearMonth(String, String)

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .year(let y): return "\(y)年"
        case .yearMonth(let y, let m):
            let names = ["", "1月", "2月", "3月", "4月", "5月", "6月",
                         "7月", "8月", "9月", "10月", "11月", "12月"]
            let mi = Int(m) ?? 0
            return "\(y)年 \(mi > 0 && mi <= 12 ? names[mi] : "\(m)月")"
        }
    }
}
