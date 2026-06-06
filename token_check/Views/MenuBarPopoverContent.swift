import SwiftUI

struct MenuBarPopoverContent: View {
    @ObservedObject var model: TokenViewModel
    @ObservedObject var dwm: DesktopWidgetManager

    var body: some View {
        VStack(spacing: 0) {
            MenuBarWidgetView(model: model)

            Divider()
                .padding(.vertical, 6)

            HStack {
                Button {
                    dwm.toggle()
                } label: {
                    Label(dwm.isVisible ? "隐藏桌面小组件" : "显示桌面小组件",
                          systemImage: "square.grid.2x2")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .focusEffectDisabled()

                Spacer()

                if dwm.isVisible {
                    Button {
                        dwm.toggleDragMode()
                    } label: {
                        Label(dwm.isDragging ? "固定" : "移动",
                              systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(dwm.isDragging ? .blue : .primary)
                    .focusEffectDisabled()
                }

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(width: 280)
    }
}
