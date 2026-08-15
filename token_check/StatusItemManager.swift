import AppKit
import SwiftUI

final class StatusItemManager: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let popover: NSPopover
    private let model: TokenViewModel
    private var contextMenu: NSMenu?

    init(model: TokenViewModel) {
        self.model = model

        popover = NSPopover()
        popover.behavior = .transient

        super.init()

        setupPopover()
        applyVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyVisibility),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    @objc private func applyVisibility() {
        let visible = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        let dockVisible = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        // 兜底：Dock 和菜单栏都隐藏时强制显示菜单栏图标，
        // 否则主窗口关闭后没有任何入口可以重新打开（app 将"打不开"）
        let effectiveVisible = visible || !dockVisible

        if effectiveVisible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.action = #selector(handleClick)
            item.button?.target = self
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Token Check")
            statusItem = item
        } else {
            guard let item = statusItem else { return }
            if popover.isShown {
                popover.performClose(nil)
            }
            contextMenu?.cancelTracking()
            contextMenu = nil
            statusItem = nil
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    private func setupPopover() {
        let contentView = MenuBarPopoverContent(
            model: model,
            openMainWindow: { [weak self] in self?.reopenMainWindowFromMenuBar() }
        )
        let hostingController = NSHostingController(rootView: contentView)
        if #available(macOS 14, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 280, height: 350)
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            showContextMenu()
        default:
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        if popover.isShown {
            popover.performClose(nil)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let activateItem = NSMenuItem(
            title: "激活窗口",
            action: #selector(activateMainWindow),
            keyEquivalent: ""
        )
        activateItem.target = self
        menu.addItem(activateItem)

        let quitItem = NSMenuItem(
            title: "退出应用",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        contextMenu = menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    @objc private func activateMainWindow() {
        reopenMainWindowFromMenuBar()
    }

    private func reopenMainWindowFromMenuBar() {
        if popover.isShown {
            popover.performClose(nil)
        }
        contextMenu?.cancelTracking()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.restoreMainWindow()
        }
    }

    private func restoreMainWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let mainPanelController = appDelegate.mainPanelController else { return }
        mainPanelController.showMainWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard contextMenu === menu else { return }
        statusItem?.menu = nil
        contextMenu = nil
    }
}
