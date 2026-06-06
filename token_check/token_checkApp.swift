import SwiftUI

@main
struct token_checkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let sceneController = AppSceneController()
    @AppStorage("showDockIcon") private var showDockIcon = true

    init() {
        appDelegate.sceneController = sceneController
    }

    var body: some Scene {
        Window("Token Check", id: "main") {
            MainWindowSceneView(sceneController: sceneController)
                .onAppear {
                    applyDockState()
                }
                .onChange(of: showDockIcon) {
                    applyDockState()
                }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }

    private func applyDockState() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
