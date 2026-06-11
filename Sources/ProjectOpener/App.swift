import AppKit
import SwiftUI
import Combine

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ProjectStore!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        if CommandLine.arguments.contains("--scan") {
            runCLIScan()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = ProjectStore()
        panelController = PanelController(store: store)
        store.onHide = { [weak self] in self?.panelController.hide() }
        store.onOpenSettings = { [weak self] in self?.showSettings() }

        setupStatusItem()

        hotKey.callback = { [weak self] in self?.panelController.toggle() }
        applyHotKey()
        store.$settings
            .map(\.hotkeyPreset)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.applyHotKey() }
            .store(in: &cancellables)

        store.refreshAll()
    }

    private func applyHotKey() {
        let preset = HotKeyPreset(rawValue: store.settings.hotkeyPreset) ?? .ctrlOptSpace
        hotKey.register(preset)
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "folder.badge.gearshape",
                                   accessibilityDescription: "ProjectOpener")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            panelController.toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Launcher", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rescan Projects", action: #selector(rescan), keyEquivalent: "r")
        menu.addItem(withTitle: "Check Remote Updates", action: #selector(checkRemotes), keyEquivalent: "u")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ProjectOpener", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Quit is handled by NSApp; every other item routes back to this delegate.
        for item in menu.items {
            item.target = (item.action == #selector(NSApplication.terminate(_:))) ? NSApp : self
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Re-opening the app (Spotlight, Finder, `open -a ProjectOpener`) summons
    /// the panel — a reliable fallback if the hotkey is taken by the system.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController.show()
        return true
    }

    @objc private func showPanel() { panelController.show() }
    @objc private func rescan() { store.rescan() }
    @objc private func checkRemotes() { store.checkRemotes() }
    @objc private func showSettingsAction() { showSettings() }

    // MARK: Settings window

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            window.title = "ProjectOpener Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        panelController.hide()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - CLI scan (debugging: `ProjectOpener --scan`)

private func runCLIScan() {
    let settings = AppSettings.load()
    print("Scanning roots: \(settings.expandedRoots) (depth \(settings.maxDepth))…")
    let start = Date()
    let projects = ProjectScanner(settings: settings).scan()
    let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
    print("Found \(projects.count) projects in \(elapsed)s\n")

    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    for p in projects.prefix(40) {
        let time = fmt.localizedString(for: p.lastActivity, relativeTo: Date())
        let cats = p.categories.map(\.rawValue).sorted().joined(separator: ",")
        var extra = ""
        if p.behind > 0 { extra += " ↓\(p.behind)" }
        if p.ahead > 0 { extra += " ↑\(p.ahead)" }
        if p.isDirty { extra += " *" }
        if p.isWorktree, let b = p.gitBranch { extra += " [\(b)]" }
        print("\(time.padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.activitySource.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) [\(cats)]\(extra)  \(p.displayPath)")
    }
}
