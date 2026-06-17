import AppKit
import SwiftUI

private final class MainPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MainPanelController: NSObject, NSWindowDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("main-window")

    private var mainWindow: MainPanel?
    private var allowsNextWindowClose = false

    func showMainWindow() {
        let window = resolvedMainWindow() ?? makeMainWindow()
        reveal(window)
    }

    func hideMainWindow() {
        guard let window = resolvedMainWindow() else { return }
        window.orderOut(nil)
        applyActivationPolicyForCurrentVisibility(showingMainWindow: false)
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

    private func resolvedMainWindow() -> MainPanel? {
        if let mainWindow, NSApp.windows.contains(where: { $0 === mainWindow }) {
            return mainWindow
        }

        if let window = NSApp.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) as? MainPanel {
            mainWindow = window
            return window
        }

        mainWindow = nil
        return nil
    }

    private func makeMainWindow() -> MainPanel {
        let hostingController = NSHostingController(rootView: ContentView())
        if #available(macOS 14.0, *) {
            hostingController.sizingOptions = []
        }
        let window = MainPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.identifier = Self.mainWindowIdentifier
        window.title = "Token Check"
        window.setContentSize(NSSize(width: 800, height: 600))
        window.minSize = NSSize(width: 800, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.animationBehavior = .utilityWindow
        window.delegate = self
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(handleMainWindowClose)
        }
        mainWindow = window
        return window
    }

    private func reveal(_ window: MainPanel) {
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
            hideMainWindow()
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
    var mainPanelController: MainPanelController?

    let model = TokenViewModel()
    let dwm = DesktopWidgetManager()
    private var statusItemManager: StatusItemManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(.regular)
        dwm.setup(model: model)
        statusItemManager = StatusItemManager(model: model, dwm: dwm)
        DispatchQueue.main.async {
            self.mainPanelController?.showMainWindow()
            if showDockIcon == false,
               self.mainPanelController?.hasVisibleMainWindow() == false {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }



    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let mainPanelController, !mainPanelController.hasVisibleMainWindow() else {
            return false
        }

        DispatchQueue.main.async {
            mainPanelController.showMainWindow()
        }

        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard UserDefaults.standard.bool(forKey: "showDockIcon") == false,
              let mainPanelController,
              !mainPanelController.hasVisibleMainWindow() else {
            return
        }

        DispatchQueue.main.async {
            mainPanelController.showMainWindow()
        }
    }
}
