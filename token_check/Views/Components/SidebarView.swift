import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: AppTab

    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(spacing: 6) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? theme.sidebarSelection : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected
                                    ? LinearGradient(
                                        colors: [theme.sidebarSelection.opacity(0.22), theme.sidebarSelection.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing)
                                    : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? theme.sidebarSelection.opacity(0.3) : .clear, lineWidth: 1)
                        )
                        .contentShape(.interaction, .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(tab.rawValue)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: 44)
        .background(theme.sidebarMaterial)
    }
}
