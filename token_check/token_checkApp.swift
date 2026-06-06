import SwiftUI

@main
struct token_checkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let mainPanelController = MainPanelController()

    init() {
        appDelegate.mainPanelController = mainPanelController
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
