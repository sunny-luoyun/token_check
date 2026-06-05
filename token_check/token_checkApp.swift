import SwiftUI

@main
struct token_checkApp: App {
    @StateObject private var model = TokenViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarWidgetView(model: model)
        } label: {
            Label(
                title: { Text(formatTokens(model.totalTokens)) },
                icon: { Image(systemName: "chart.bar.fill") }
            )
        }
        .menuBarExtraStyle(.window)
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
