import AppKit

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let store: ProjectStore
    private let launcher: LauncherViewController
    private var keyMonitor: Any?

    init(store: ProjectStore) {
        self.store = store
        launcher = LauncherViewController(store: store)
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: LauncherViewController.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        launcher.view.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = launcher.view
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.minY + vf.height * 0.72 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        store.panelWillShow()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        launcher.focusSearch()
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Give menus/popovers a beat; only hide if focus truly left the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow,
                  !self.store.isPinned else { return }
            self.hide()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 53: // esc
                self.hide()
                return nil
            case 125: // down
                self.store.moveSelection(1)
                return nil
            case 126: // up
                self.store.moveSelection(-1)
                return nil
            case 123: // left — fold group (only when not editing a query)
                guard self.store.query.isEmpty else { return event }
                self.store.collapseSelectedGroup()
                return nil
            case 124: // right — unfold group
                guard self.store.query.isEmpty else { return event }
                self.store.expandSelectedGroup()
                return nil
            case 36: // return
                self.store.openSelected(reveal: event.modifierFlags.contains(.command))
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}
