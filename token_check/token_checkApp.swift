import SwiftUI

@main
struct token_checkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let sceneController = AppSceneController()

    init() {
        appDelegate.sceneController = sceneController
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
