import SwiftUI

struct CostBreakdownTable: View {
    let breakdown: [ModelCostBreakdown]

    var body: some View {
        Table(breakdown) {
            TableColumn("Model") { item in
                Text(item.displayName)
                    .font(.caption.weight(.medium))
            }
            .width(min: 100, ideal: 200, max: 400)

            TableColumn("会话数") { item in
                Text("\(item.sessions)")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 65, max: 100)

            TableColumn("输入（未命中）") { item in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokens(item.cacheMissTokens))
                        .font(.caption.monospaced())
                    Text(formatCost(item.missCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
            }
            .width(min: 80, ideal: 130, max: 200)

            TableColumn("缓存命中") { item in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokens(item.cacheHitTokens))
                        .font(.caption.monospaced())
                    Text(formatCost(item.hitCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.green)
                }
            }
            .width(min: 80, ideal: 130, max: 200)

            TableColumn("输出") { item in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokens(item.outputTokens))
                        .font(.caption.monospaced())
                    Text(formatCost(item.outputCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.blue)
                }
            }
            .width(min: 80, ideal: 130, max: 200)

            TableColumn("推理") { item in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokens(item.reasoningTokens))
                        .font(.caption.monospaced())
                    Text(formatCost(item.reasoningCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.purple)
                }
            }
            .width(min: 80, ideal: 130, max: 200)

            TableColumn("总费用") { item in
                Text(formatCost(item.totalCost))
                    .font(.caption.monospaced().bold())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(item.totalCost > 0 ? .primary : .secondary)
            }
            .width(min: 70, ideal: 100, max: 150)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            String(format: "%.2fB", Double(n) / 1_000_000_000)
        } else if n >= 1_000_000 {
            String(format: "%.2fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.1fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }

    private func formatCost(_ c: Double) -> String {
        String(format: "$%.3f", c)
    }
}
