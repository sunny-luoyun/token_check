import AppKit
import SwiftUI

struct MenuBarPopoverContent: View {
    @ObservedObject var model: TokenViewModel
    let openMainWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MenuBarWidgetView(model: model)

            Divider()
                .padding(.vertical, 6)

            HStack(spacing: 0) {
                toolbarButton(icon: "macwindow", label: "打开主窗口", action: openMainWindow)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .padding(6)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(width: 280)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void, tint: Color? = nil) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint ?? .primary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
