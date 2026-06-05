import AppKit
import SwiftUI

final class AppSceneController {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("main-window")

    var openMainWindow: (() -> Void)?
    private weak var mainWindow: NSWindow?

    func configureMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = Self.mainWindowIdentifier
        mainWindow = window
    }

    func restoreMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hasVisibleMainWindow() -> Bool {
        if let mainWindow {
            return mainWindow.isVisible
        }

        return NSApp.windows.contains { window in
            window.identifier == Self.mainWindowIdentifier && window.isVisible
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var sceneController: AppSceneController?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let sceneController, !sceneController.hasVisibleMainWindow() else {
            return false
        }

        DispatchQueue.main.async {
            sceneController.restoreMainWindow()
        }

        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard UserDefaults.standard.bool(forKey: "showDockIcon") == false,
              let sceneController,
              !sceneController.hasVisibleMainWindow() else {
            return
        }

        DispatchQueue.main.async {
            sceneController.restoreMainWindow()
        }
    }
}

struct MainWindowSceneView: View {
    @Environment(\.openWindow) private var openWindow
    let sceneController: AppSceneController

    var body: some View {
        ContentView()
            .background(MainWindowAccessor(sceneController: sceneController))
            .onAppear {
                sceneController.openMainWindow = {
                    openWindow(id: "main")
                }
            }
    }
}

struct MainWindowAccessor: NSViewRepresentable {
    let sceneController: AppSceneController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            sceneController.configureMainWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            sceneController.configureMainWindow(nsView.window)
        }
    }
}
