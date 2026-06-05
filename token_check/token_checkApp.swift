import SwiftUI

@main
struct token_checkApp: App {
    @StateObject private var model = TokenViewModel()
    @StateObject private var dwm = DesktopWidgetManager()
    @AppStorage("showDockIcon") private var showDockIcon = true

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }

        MenuBarExtra {
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
                    }

                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .frame(width: 280)
            .onAppear {
                dwm.setup(model: model)
                applyDockState()
            }
        } label: {
            Label(
                title: { Text(formatTokens(model.totalTokens)) },
                icon: { Image(systemName: "chart.bar.fill") }
            )
        }
        .menuBarExtraStyle(.window)
    }

    private func applyDockState() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon {
            NSApp.activate(ignoringOtherApps: true)
        }
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
