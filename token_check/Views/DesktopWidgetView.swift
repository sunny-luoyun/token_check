import SwiftUI

struct DesktopWidgetView: View {
    @ObservedObject var model: TokenViewModel

    private var total7Day: Int {
        model.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

    @State private var barAnimated = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(maxHeight: .infinity)
            } else if let error = model.error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            } else if let usage = model.usage {
                HStack {
                    Label("今日 Token", systemImage: "chart.bar.fill")
                        .foregroundStyle(.blue)
                        .font(.headline)
                        .labelStyle(.iconOnly)
                    Text(formatTokens(model.adjustedTotal))
                        .font(.title2.monospaced().bold())
                        .foregroundStyle(.blue)
                    if model.hasRollback {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text("+\(formatTokens(model.rollbackTotal))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                    }
                    Text(formatCost(usage.todayCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    Spacer()
                    if model.deepseekLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else if let balance = model.deepseekBalance {
                        Text("DeepSeek余额 ¥\(balance)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)

                HStack(spacing: 0) {
                    statItem("输入", formatTokens(model.adjustedInput), .blue)
                    Spacer()
                    statItem("缓存", formatTokens(model.adjustedCacheRead), .purple)
                    Spacer()
                    statItem("输出", formatTokens(model.adjustedOutput), .green)
                    Spacer()
                    statItem("会话", "\(usage.sessionCount)", .orange)
                }
                .font(.caption2)
                .padding(.horizontal, 14)

                if !usage.dailyTokens.isEmpty {
                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)

                    HStack(spacing: 0) {
                        Text("近7天")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("共 \(formatTokens(total7Day))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)

                    let maxVal = max(usage.dailyTokens.map(\.totalTokens).max() ?? 1, 1)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(usage.dailyTokens.enumerated()), id: \.element.id) { index, item in
                                let ratio = CGFloat(item.totalTokens) / CGFloat(maxVal)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.blue.gradient)
                                    .frame(height: barAnimated ? max(4, ratio * geo.size.height) : 2)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                                    .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(index) * 0.04), value: barAnimated)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        .onAppear {
            model.refresh()
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) {
                barAnimated = true
            }
        }
    }

    private func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func formatCost(_ c: Double) -> String {
        String(format: "¥%.2f", c)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.0fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }
}
