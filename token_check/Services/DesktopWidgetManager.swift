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
        content.sizingOptions = []
        win.identifier = NSUserInterfaceItemIdentifier("desktop-widget")
        win.level = desktopWidgetLevel
        win.styleMask = [.titled, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor.clear
        win.isOpaque = false
        win.title = ""
        win.ignoresMouseEvents = true
        win.hasShadow = true

        let savedFrame = UserDefaults.standard.string(forKey: "desktop_widget_frame")
            .flatMap { NSRectFromString($0) }
        let width: CGFloat = 340
        let height: CGFloat = 195
        if let saved = savedFrame, saved.size.width > 0 {
            win.setFrame(NSRect(x: saved.minX, y: saved.minY, width: width, height: height), display: true)
        } else {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            let x = screen.maxX - width - 20
            let y = screen.maxY - height - 22
            win.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
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
