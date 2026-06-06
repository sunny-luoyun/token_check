import AppKit
import SwiftUI

final class AppSceneController: NSObject, NSWindowDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("main-window")

    private var mainWindow: NSWindow?
    private var allowsNextWindowClose = false

    func showMainWindow() {
        let window = resolvedMainWindow() ?? makeMainWindow()
        reveal(window)
    }

    func restoreMainWindow() {
        showMainWindow()
    }

    func hasVisibleMainWindow() -> Bool {
        if let mainWindow {
            return mainWindow.isVisible
        }

        return NSApp.windows.contains { window in
            window.identifier == Self.mainWindowIdentifier && window.isVisible
        }
    }

    private func resolvedMainWindow() -> NSWindow? {
        if let mainWindow, NSApp.windows.contains(where: { $0 === mainWindow }) {
            return mainWindow
        }

        if let window = NSApp.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            mainWindow = window
            return window
        }

        mainWindow = nil
        return nil
    }

    private func makeMainWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: ContentView())
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = Self.mainWindowIdentifier
        window.title = "Token Check"
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.titled)
        window.setContentSize(NSSize(width: 800, height: 600))
        window.minSize = NSSize(width: 800, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(handleMainWindowClose)
        }
        mainWindow = window
        return window
    }

    private func reveal(_ window: NSWindow) {
        applyActivationPolicyForCurrentVisibility(showingMainWindow: true)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func applyActivationPolicyForCurrentVisibility(showingMainWindow: Bool) {
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        let policy: NSApplication.ActivationPolicy

        if showDockIcon || showingMainWindow {
            policy = .regular
        } else {
            policy = .accessory
        }

        NSApp.setActivationPolicy(policy)
    }

    @objc private func handleMainWindowClose() {
        guard let window = resolvedMainWindow() else { return }

        if UserDefaults.standard.bool(forKey: "showDockIcon") == false {
            window.orderOut(nil)
            applyActivationPolicyForCurrentVisibility(showingMainWindow: false)
            return
        }

        allowsNextWindowClose = true
        window.performClose(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.identifier == Self.mainWindowIdentifier else {
            return true
        }

        if allowsNextWindowClose {
            allowsNextWindowClose = false
            mainWindow = nil
            return true
        }

        guard UserDefaults.standard.bool(forKey: "showDockIcon") == false else {
            mainWindow = nil
            return true
        }

        sender.orderOut(nil)
        applyActivationPolicyForCurrentVisibility(showingMainWindow: false)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier,
              mainWindow === window else {
            return
        }

        mainWindow = nil
        applyActivationPolicyForCurrentVisibility(showingMainWindow: false)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var sceneController: AppSceneController?

    let model = TokenViewModel()
    let dwm = DesktopWidgetManager()
    private var statusItemManager: StatusItemManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(.regular)
        dwm.setup(model: model)
        statusItemManager = StatusItemManager(model: model, dwm: dwm)
        DispatchQueue.main.async {
            self.sceneController?.showMainWindow()
            if showDockIcon == false,
               self.sceneController?.hasVisibleMainWindow() == false {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }



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
