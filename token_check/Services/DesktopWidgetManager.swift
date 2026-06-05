import AppKit
import Combine
import SwiftUI

private let desktopWidgetLevel: NSWindow.Level = {
    let backstop = CGWindowLevelForKey(.backstopMenu)
    return .init(rawValue: Int(backstop) + 1)
}()

private class DesktopWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopWidgetManager: ObservableObject {
    @Published var isVisible = false
    @Published var isDragging = false

    private var window: NSWindow?
    private weak var model: TokenViewModel?

    func setup(model: TokenViewModel) {
        self.model = model
    }

    func show() {
        if let window, window.isVisible {
            window.orderFront(nil)
            isVisible = true
            return
        }
        guard let model else { return }

        let content = NSHostingController(rootView: DesktopWidgetView(model: model))
        let win = DesktopWidgetWindow(contentViewController: content)
        win.identifier = NSUserInterfaceItemIdentifier("desktop-widget")
        win.level = desktopWidgetLevel
        win.styleMask = [.titled, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 340, height: 128))
        win.backgroundColor = NSColor.clear
        win.isOpaque = false
        win.title = ""
        win.ignoresMouseEvents = true
        win.hasShadow = true

        if let saved = UserDefaults.standard.string(forKey: "desktop_widget_frame") {
            win.setFrame(NSRectFromString(saved), display: true)
        } else {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            let x = screen.maxX - 360
            let y = screen.maxY - 150
            win.setFrame(NSRect(x: x, y: y, width: 340, height: 128), display: false)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: win, queue: .main
        ) { _ in
            UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: "desktop_widget_frame")
        }

        window = win
        win.orderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
        if isDragging {
            isDragging = false
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func toggleDragMode() {
        isDragging.toggle()
        if isDragging {
            window?.level = .floating
            window?.ignoresMouseEvents = false
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.level = desktopWidgetLevel
            window?.ignoresMouseEvents = true
        }
    }
}
