import AppKit
import SwiftUI

final class StatusItemManager: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: TokenViewModel
    private let dwm: DesktopWidgetManager

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
        let contentView = MenuBarPopoverContent(model: model, dwm: dwm)
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
        let menu = NSMenu()
        menu.autoenablesItems = false

        let widgetItem = NSMenuItem(
            title: dwm.isVisible ? "隐藏桌面小组件" : "显示桌面小组件",
            action: #selector(toggleWidget),
            keyEquivalent: ""
        )
        widgetItem.target = self
        widgetItem.state = dwm.isVisible ? .on : .off
        menu.addItem(widgetItem)

        menu.addItem(NSMenuItem(
            title: "设置...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        menu.addItem(NSMenuItem(
            title: "退出应用",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        guard let button = statusItem.button else { return }
        if #available(macOS 14, *) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else {
            guard let event = NSApp.currentEvent else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }

    @objc private func toggleWidget() {
        dwm.toggle()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
