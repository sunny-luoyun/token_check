import AppKit
import SwiftUI

final class StatusItemManager: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: TokenViewModel
    private let dwm: DesktopWidgetManager
    private var contextMenu: NSMenu?

    init(model: TokenViewModel, dwm: DesktopWidgetManager) {
        self.model = model
        self.dwm = dwm

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient

        super.init()

        setupButton()
        setupPopover()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateButtonLabel()
    }

    private func updateButtonLabel() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Token Check")
    }

    private func setupPopover() {
        let contentView = MenuBarPopoverContent(
            model: model,
            dwm: dwm,
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
        guard let button = statusItem.button else { return }
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

        let widgetItem = NSMenuItem(
            title: dwm.isVisible ? "隐藏桌面小组件" : "显示桌面小组件",
            action: #selector(toggleWidget),
            keyEquivalent: ""
        )
        widgetItem.target = self
        widgetItem.state = dwm.isVisible ? .on : .off
        menu.addItem(widgetItem)

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
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc private func toggleWidget() {
        dwm.toggle()
    }

    @objc private func activateMainWindow() {
        reopenMainWindowFromMenuBar()
    }

    private func reopenMainWindowFromMenuBar() {
        if popover.isShown {
            popover.performClose(nil)
        }

        if let menu = contextMenu {
            menu.cancelTracking()
        }

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
        statusItem.menu = nil
        contextMenu = nil
    }
}
