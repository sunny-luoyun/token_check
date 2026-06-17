import SwiftUI

enum AppTab: String, CaseIterable {
    case cost = "费用"
    case session = "会话"
    case trend = "趋势"

    var icon: String {
        switch self {
        case .cost: return "yensign.circle.fill"
        case .session: return "list.bullet"
        case .trend: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .cost

    var body: some View {
        VStack(spacing: 0) {
            customTabBar

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
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: selectedTab)
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isSelected ? Color.blue.opacity(0.1) : .clear)
                    )
                    .contentShape(.interaction, .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}
