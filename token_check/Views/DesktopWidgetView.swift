import SwiftUI
import Combine

struct DesktopWidgetView: View {
    @ObservedObject var model: TokenViewModel
    @AppStorage("refreshMinutes") private var refreshMinutes = 5
    @State private var timerCancellable: AnyCancellable?

    private var total7Day: Int {
        model.usage?.dailyTokens.map(\.totalTokens).reduce(0, +) ?? 0
    }

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
            } else if let usage = model.usage {
                HStack {
                    Label("今日 Token", systemImage: "chart.bar.fill")
                        .foregroundStyle(.blue)
                        .font(.headline)
                        .labelStyle(.iconOnly)
                    Text(formatTokens(usage.totalTokens))
                        .font(.title2.monospaced().bold())
                        .foregroundStyle(.blue)
                    Text(formatCost(usage.todayCost))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                HStack(spacing: 0) {
                    statItem("输入", formatTokens(usage.inputTokens), .blue)
                    Spacer()
                    statItem("缓存", formatTokens(usage.cacheReadTokens), .purple)
                    Spacer()
                    statItem("输出", formatTokens(usage.outputTokens), .green)
                    Spacer()
                    statItem("会话", "\(usage.sessionCount)", .orange)
                }
                .font(.caption2)
                .padding(.horizontal, 14)
                .padding(.top, 6)

                if !usage.dailyTokens.isEmpty {
                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)

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
                    HStack(spacing: 2) {
                        ForEach(usage.dailyTokens) { item in
                            let ratio = CGFloat(item.totalTokens) / CGFloat(maxVal)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.blue.gradient)
                                .frame(maxHeight: max(4, ratio * 18))
                                .frame(maxHeight: 18, alignment: .bottom)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        .onAppear {
            model.refresh()
            startRefreshTimer()
        }
        .onDisappear {
            timerCancellable?.cancel()
        }
        .onChange(of: refreshMinutes) { _, _ in
            startRefreshTimer()
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

    private func startRefreshTimer() {
        timerCancellable?.cancel()
        let interval = max(TimeInterval(refreshMinutes), 1) * 60
        timerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak model] _ in model?.refresh() }
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
