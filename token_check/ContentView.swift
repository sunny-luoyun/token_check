import SwiftUI

enum AppTab: String, CaseIterable {
    case cost = "费用"
    case session = "会话"
    case trend = "趋势"
    case stats = "统计"

    var icon: String {
        switch self {
        case .cost: return "yensign.circle.fill"
        case .session: return "list.bullet"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .stats: return "chart.bar.fill"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .cost

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selectedTab: $selectedTab)

            Divider()

            ZStack {
                if selectedTab == .cost {
                    CostDashboardView()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if selectedTab == .session {
                    SessionListView()
                        .transition(.push(from: selectedTab == .cost ? .trailing : .leading))
                }
                if selectedTab == .trend {
                    DailyTrendView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if selectedTab == .stats {
                    StatsView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: selectedTab)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
