import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            CostDashboardView()
                .tabItem {
                    Label("费用", systemImage: "yensign.circle.fill")
                }

            SessionListView()
                .tabItem {
                    Label("会话", systemImage: "list.bullet")
                }

            DailyTrendView()
                .tabItem {
                    Label("趋势", systemImage: "chart.line.uptrend.xyaxis")
                }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
