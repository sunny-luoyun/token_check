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
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
