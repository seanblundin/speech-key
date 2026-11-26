import AppKit
import SwiftUI

/// Shows the panel under the menu-bar icon. The view is built once and kept, so opening it is
/// instant; clicking anywhere else closes it.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    let model: PanelModel
    private let popover = NSPopover()
    /// Called just before the panel opens, so it shows fresh state.
    var willOpen: (() -> Void)?
    /// Called after it closes, so focus can go back to the app that had it.
    var didClose: (() -> Void)?
    /// Where the panel hangs from when the menu-bar icon isn't on screen (a full menu bar).
    private var anchor: NSWindow?

    init(model: PanelModel) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: PanelView(model: model, history: model.history))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: PanelView.size)
        popover.contentViewController = host
        popover.contentSize = PanelView.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        model.actions.close = { [weak self] in self?.close() }
    }

    var isOpen: Bool { popover.isShown }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown { close() } else { open(from: button) }
    }

    func open(from button: NSStatusBarButton) {
        willOpen?()
        // Typing in the panel needs Utter to be the active app; macOS gives focus back on close.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Opens the panel with no menu-bar icon to hang it from (the icon is hidden behind a full
    /// menu bar): from the top-right corner of the screen, where the icon would be.
    func openWithoutIcon() {
        guard !popover.isShown, let screen = NSScreen.main else { return }
        let frame = NSRect(x: screen.visibleFrame.maxX - 60, y: screen.visibleFrame.maxY - 2, width: 24, height: 2)
        let window = anchor ?? {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            return w
        }()
        anchor = window
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        guard let view = window.contentView else { return }
        willOpen?()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        // A fix left waiting on "Add to your glossary?" still counts; it just isn't added.
        if model.prompt != nil { model.answerPrompt(add: false) }
        model.editing = nil
        model.renaming = nil
        if model.page == .settings { model.page = .history }
        anchor?.orderOut(nil)
        didClose?()
    }
}
