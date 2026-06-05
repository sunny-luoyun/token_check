import SwiftUI

struct SettingsView: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("refreshMinutes") private var refreshMinutes = 5

    var body: some View {
        Form {
            Section("外观") {
                Toggle("显示 Dock 图标", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { newValue in
                        NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                        if newValue {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
            }

            Section("刷新") {
                Picker("自动刷新间隔", selection: $refreshMinutes) {
                    Text("1 分钟").tag(1)
                    Text("2 分钟").tag(2)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
                Text("修改后立即生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("桌面小组件") {
                HStack {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .foregroundStyle(.blue)
                    Text("菜单栏点击「移动」可拖拽，再点「固定」锁定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 300)
    }
}
