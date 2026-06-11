import AppKit
import Combine

// MARK: - Small AppKit helpers

private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

private func makeSymbolView(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular,
                            tint: NSColor) -> NSImageView {
    let view = NSImageView()
    view.image = IconCache.symbol(name, size: size, weight: weight)
    view.contentTintColor = tint
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.required, for: .horizontal)
    return view
}

/// A capsule pill containing a short label (used for branch names, counts, badges).
private func makePill(_ text: String, size: CGFloat, weight: NSFont.Weight,
                      fg: NSColor, bg: NSColor) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = bg.cgColor
    container.translatesAutoresizingMaskIntoConstraints = false
    let label = makeLabel(text, size: size, weight: weight, color: fg)
    container.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
        label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
        label.topAnchor.constraint(equalTo: container.topAnchor, constant: 1.5),
        label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1.5),
    ])
    container.layer?.cornerRadius = (size + 6) / 2
    return container
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, image: NSImage? = nil, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.image = image
        self.state = checked ? .on : .off
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// NSButton that runs a closure; supports an optional rounded background.
private final class ClosureButton: NSButton {
    var handler: () -> Void = {}

    static func make(handler: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.title = ""
        button.handler = handler
        button.target = button
        button.action = #selector(fire)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func fire() { handler() }
}

private final class LauncherTableView: NSTableView {
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return contextMenuForRow?(row)
    }
}

// MARK: - Launcher view controller (AppKit)

final class LauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                    NSTextFieldDelegate {
    static let panelSize = NSSize(width: 740, height: 560)

    private let store: ProjectStore
    private var cancellables = Set<AnyCancellable>()
    private var reloadPending = false
    private var lastSelectedID: String?

    private enum Row {
        case header(String)
        case project(DisplayItem)
        case showOlder(count: Int, shown: Bool)
    }

    private var rows: [Row] = []
    private var rowForItemIndex: [Int] = []   // store.visibleItems index -> table row
    private var itemIndexForRow: [Int?] = []  // table row -> store.visibleItems index

    let searchField = NSTextField()
    private let spinner = NSProgressIndicator()
    private let pinButton = ClosureButton.make(handler: {})
    private let appButton = ClosureButton.make(handler: {})
    private var chipButtons: [(kind: FilterKind, button: ClosureButton, label: NSTextField, icon: NSImageView)] = []
    private let tableView = LauncherTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = makeLabel("", size: 14.5, color: .secondaryLabelColor)
    private let countLabel = makeLabel("", size: 12, color: .secondaryLabelColor)
    private let fetchLabel = makeLabel("checking remotes…", size: 11, color: .tertiaryLabelColor)

    init(store: ProjectStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: View construction

    override func loadView() {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor

        // Neutral wash so wallpaper colors don't tint the panel.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.62).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        view = effect
        buildHeader()
        buildChips()
        buildList()
        buildFooter()
        layoutSections()
    }

    private let headerStack = NSStackView()
    private let chipsStack = NSStackView()
    private let footerStack = NSStackView()
    private let divider1 = NSBox()
    private let divider2 = NSBox()

    private func buildHeader() {
        headerStack.orientation = .horizontal
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let glass = makeSymbolView("magnifyingglass", size: 17, weight: .medium, tint: .secondaryLabelColor)

        searchField.placeholderString = "Search projects…"
        searchField.font = .systemFont(ofSize: 20)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.init(1), for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        pinButton.handler = { [weak self] in self?.store.isPinned.toggle() }
        appButton.handler = { [weak self] in self?.showAppMenu() }

        headerStack.addArrangedSubview(glass)
        headerStack.addArrangedSubview(searchField)
        headerStack.addArrangedSubview(spinner)
        headerStack.addArrangedSubview(pinButton)
        headerStack.addArrangedSubview(appButton)
    }

    private func buildChips() {
        chipsStack.orientation = .horizontal
        chipsStack.spacing = 6
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        for kind in FilterKind.allCases {
            let button = ClosureButton.make { [weak self] in
                guard let self else { return }
                let selected = self.store.filterKind == kind
                self.store.filterKind = (selected && kind != .all) ? .all : kind
                self.store.selectedIndex = 0
            }
            button.wantsLayer = true
            button.layer?.cornerRadius = 12
            let icon = makeSymbolView(kind.symbol, size: 11, tint: .labelColor)
            let label = makeLabel(kind.title, size: 12.5, weight: .medium)
            let inner = NSStackView(views: [icon, label])
            inner.orientation = .horizontal
            inner.spacing = 4
            inner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 9),
                inner.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -9),
                inner.topAnchor.constraint(equalTo: button.topAnchor, constant: 4.5),
                inner.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4.5),
            ])
            chipsStack.addArrangedSubview(button)
            chipButtons.append((kind, button, label, icon))
        }
        chipsStack.addArrangedSubview(NSView()) // spacer
    }

    private func buildList() {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        column.width = Self.panelSize.width - 16
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.style = .plain
        tableView.contextMenuForRow = { [weak self] row in self?.contextMenu(forRow: row) }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        scrollView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
        ])
    }

    private func buildFooter() {
        footerStack.orientation = .horizontal
        footerStack.spacing = 10
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        let hint = makeLabel("↩ open   ⌘↩ reveal   ← → fold   esc close", size: 11,
                             color: .tertiaryLabelColor)
        let refresh = ClosureButton.make { [weak self] in self?.store.refreshAll() }
        refresh.image = IconCache.symbol("arrow.clockwise", size: 13)
        refresh.contentTintColor = .labelColor
        refresh.toolTip = "Rescan and check remotes"
        let gear = ClosureButton.make { [weak self] in self?.store.onOpenSettings?() }
        gear.image = IconCache.symbol("gearshape", size: 13)
        gear.contentTintColor = .labelColor
        gear.toolTip = "Settings"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footerStack.addArrangedSubview(countLabel)
        footerStack.addArrangedSubview(fetchLabel)
        footerStack.addArrangedSubview(spacer)
        footerStack.addArrangedSubview(hint)
        footerStack.addArrangedSubview(refresh)
        footerStack.addArrangedSubview(gear)
    }

    private func layoutSections() {
        for divider in [divider1, divider2] {
            divider.boxType = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
        }
        for sub in [headerStack, chipsStack, divider1, scrollView, divider2, footerStack] {
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

            chipsStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),
            chipsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            chipsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            divider1.topAnchor.constraint(equalTo: chipsStack.bottomAnchor, constant: 9),
            divider1.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider1.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            divider2.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            footerStack.topAnchor.constraint(equalTo: divider2.bottomAnchor, constant: 8),
            footerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            footerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            footerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)
        applyState()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: State -> UI

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadPending = false
            self?.applyState()
        }
    }

    private func applyState() {
        rows = buildRows()

        if searchField.stringValue != store.query {
            searchField.stringValue = store.query
        }
        if store.isScanning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        pinButton.image = IconCache.symbol(store.isPinned ? "pin.fill" : "pin", size: 13)
        pinButton.contentTintColor = store.isPinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = store.isPinned ? "Unpin — panel hides when it loses focus"
                                           : "Pin — keep the panel open"
        if let app = store.defaultApp {
            appButton.image = IconCache.appIcon(app, size: 22)
            appButton.toolTip = "Default app for opening projects"
        }

        for chip in chipButtons {
            let selected = store.filterKind == chip.kind
            chip.button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
                : NSColor.labelColor.withAlphaComponent(0.06).cgColor
            let count = store.count(for: chip.kind)
            chip.label.stringValue = (chip.kind == .all || count == 0)
                ? chip.kind.title : "\(chip.kind.title)  \(count)"
        }

        countLabel.stringValue = "\(store.visibleItems.count) of \(store.projects.count) projects"
        fetchLabel.isHidden = !store.isFetching
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = store.isScanning ? "Scanning projects…" : "No projects found"

        tableView.reloadData()

        let selectedID = selectedItem()?.id
        if selectedID != lastSelectedID, let idx = currentItemIndex(),
           idx < rowForItemIndex.count {
            tableView.scrollRowToVisible(rowForItemIndex[idx])
        }
        lastSelectedID = selectedID

        if let item = selectedItem(), item.project.categories.contains(.git) {
            store.requestRemoteDetail(item.project)
        }
    }

    private func buildRows() -> [Row] {
        var result: [Row] = []
        rowForItemIndex = []
        var previousBucket: TimeBucket?
        let items = store.visibleItems
        for item in items {
            if item.depth == 0, let bucket = item.bucket, bucket != previousBucket {
                result.append(.header(bucket.label))
                previousBucket = bucket
            }
            rowForItemIndex.append(result.count)
            result.append(.project(item))
        }
        if store.query.isEmpty, store.olderCount > 0 {
            result.append(.showOlder(count: store.olderCount, shown: store.showOlder))
        }
        itemIndexForRow = Array(repeating: nil, count: result.count)
        for (itemIdx, rowIdx) in rowForItemIndex.enumerated() {
            itemIndexForRow[rowIdx] = itemIdx
        }
        return result
    }

    private func currentItemIndex() -> Int? {
        let items = store.visibleItems
        guard !items.isEmpty else { return nil }
        return min(store.selectedIndex, items.count - 1)
    }

    private func selectedItem() -> DisplayItem? {
        guard let idx = currentItemIndex() else { return nil }
        return store.visibleItems[idx]
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        store.query = searchField.stringValue
        store.selectedIndex = 0
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 30
        case .showOlder: return 34
        case .project(let item):
            var height: CGFloat = item.depth > 0 ? 46 : 52
            if isSelected(item), item.project.categories.contains(.git) {
                height += detailHeight(for: item.project)
            }
            return height
        }
    }

    private func isSelected(_ item: DisplayItem) -> Bool {
        selectedItem()?.id == item.id
    }

    private func detailHeight(for project: Project) -> CGFloat {
        var height: CGFloat = 2 + 18 + 8 // padding + meta line + bottom
        if let subject = project.lastCommitSubject, !subject.isEmpty { height += 18 }
        if project.behind > 0 {
            let detail = store.remoteDetails[project.path]
            let lines = min(detail?.incoming.count ?? 1, 4)
            height += CGFloat(max(lines, 1)) * 18
            if project.behind > 4 { height += 17 }
        }
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = NSView()
            let label = makeLabel(title.uppercased(), size: 11, weight: .semibold,
                                  color: .tertiaryLabelColor)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell

        case .showOlder(let count, let shown):
            let cell = NSView()
            let button = ClosureButton.make { [weak self] in self?.store.showOlder.toggle() }
            let title = shown ? "Hide older projects"
                              : "Show \(count) older project\(count == 1 ? "" : "s")"
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.secondaryLabelColor])
            cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case .project(let item):
            return ProjectCellView(item: item, store: store, isSelected: isSelected(item),
                                   detailHeight: detailHeight(for: item.project))
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < itemIndexForRow.count, let itemIdx = itemIndexForRow[row] else { return }
        store.selectedIndex = itemIdx
        store.openSelected()
    }

    // MARK: Menus

    private func showAppMenu() {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Open with ↩"))
        for app in store.installedApps.filter({ !$0.isTerminal }) {
            menu.addItem(ActionMenuItem(title: app.name, image: IconCache.appIcon(app, size: 18),
                                        checked: app.id == store.settings.defaultAppID) { [weak self] in
                self?.store.setDefaultApp(app)
            })
        }
        menu.addItem(.sectionHeader(title: "Terminal button"))
        for app in store.installedApps.filter(\.isTerminal) {
            menu.addItem(ActionMenuItem(title: app.name, image: IconCache.appIcon(app, size: 18),
                                        checked: app.id == store.settings.terminalAppID) { [weak self] in
                self?.store.setTerminalApp(app)
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: appButton.bounds.height + 6), in: appButton)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row < itemIndexForRow.count, let itemIdx = itemIndexForRow[row] else { return nil }
        let project = store.visibleItems[itemIdx].project
        let menu = NSMenu()
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for app in store.installedApps {
            sub.addItem(ActionMenuItem(title: app.name, image: IconCache.appIcon(app, size: 18)) { [weak self] in
                self?.store.open(project, with: app)
            })
        }
        openWith.submenu = sub
        menu.addItem(openWith)
        menu.addItem(ActionMenuItem(title: "Reveal in Finder") { [weak self] in
            self?.store.reveal(project)
        })
        if project.overleafURL != nil {
            menu.addItem(ActionMenuItem(title: "Open on Overleaf") { [weak self] in
                self?.store.openOverleaf(project)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        })
        return menu
    }
}

// MARK: - Project row cell

private final class ProjectCellView: NSView {
    private let item: DisplayItem
    private let store: ProjectStore
    private let isSelected: Bool
    private let background = NSView()
    private let statusStack = NSStackView()
    private let actionsStack = NSStackView()
    private var tracking: NSTrackingArea?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt
    }()

    init(item: DisplayItem, store: ProjectStore, isSelected: Bool, detailHeight: CGFloat) {
        self.item = item
        self.store = store
        self.isSelected = isSelected
        super.init(frame: .zero)
        build(detailHeight: detailHeight)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var project: Project { item.project }
    private var indent: CGFloat { item.depth > 0 ? 26 : 0 }

    private func build(detailHeight: CGFloat) {
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        updateBackground(hovering: false)

        let iconSize: CGFloat = item.depth > 0 ? 27 : 34
        let icon = NSImageView(image: IconCache.projectIcon(project, size: iconSize))
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Title line: name + branch pill + category glyphs + disclosure pill
        let titleStack = NSStackView()
        titleStack.orientation = .horizontal
        titleStack.spacing = 5
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.addArrangedSubview(makeLabel(project.name, size: 15, weight: .semibold))
        if project.isWorktree, let branch = project.gitBranch {
            titleStack.addArrangedSubview(makePill(branch, size: 11, weight: .medium,
                                                   fg: .systemPurple,
                                                   bg: NSColor.systemPurple.withAlphaComponent(0.16)))
        }
        for cat in ProjectCategory.allCases where project.categories.contains(cat) && cat != .worktree {
            let glyph = makeSymbolView(cat.symbol, size: 10, tint: NSColor(cat.tint))
            glyph.toolTip = cat.title
            titleStack.addArrangedSubview(glyph)
        }
        if item.childCount > 0 {
            let pill = ClosureButton.make { [store, project] in store.toggleGroup(project.path) }
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.14).cgColor
            pill.layer?.cornerRadius = 9
            pill.image = IconCache.symbol(item.isExpanded ? "chevron.down" : "chevron.right",
                                          size: 8.5, weight: .bold)
            pill.contentTintColor = .systemPurple
            pill.attributedTitle = NSAttributedString(
                string: " \(item.childCount)",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.systemPurple])
            pill.imagePosition = .imageLeading
            pill.toolTip = item.isExpanded ? "Collapse worktrees"
                : "Show \(item.childCount) worktree\(item.childCount == 1 ? "" : "s")"
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 18),
                pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            ])
            titleStack.addArrangedSubview(pill)
        }

        let path = makeLabel(subtitle, size: 12, color: .tertiaryLabelColor)
        path.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleStack, path])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        buildStatus()
        buildActions()
        let trailing = NSView()
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.addSubview(statusStack)
        trailing.addSubview(actionsStack)
        actionsStack.isHidden = true
        for stack in [statusStack, actionsStack] {
            NSLayoutConstraint.activate([
                stack.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: trailing.leadingAnchor),
            ])
        }

        addSubview(icon)
        addSubview(textStack)
        addSubview(trailing)

        let rowHeight: CGFloat = item.depth > 0 ? 46 : 52
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent + 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: (rowHeight - iconSize) / 2),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),

            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            trailing.heightAnchor.constraint(equalToConstant: 26),
            trailing.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        if isSelected, project.categories.contains(.git) {
            buildDetail(below: rowHeight)
        }
    }

    private var subtitle: String {
        if item.depth > 0, let main = project.worktreeOf, project.path.hasPrefix(main + "/") {
            return String(project.path.dropFirst(main.count + 1))
        }
        return project.displayPath
    }

    private func buildStatus() {
        statusStack.orientation = .horizontal
        statusStack.spacing = 6
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        if project.behind > 0 {
            let pill = makePill("↓\(project.behind)", size: 11, weight: .semibold,
                                fg: .systemBlue, bg: NSColor.systemBlue.withAlphaComponent(0.18))
            pill.toolTip = "\(project.behind) commits behind remote"
            statusStack.addArrangedSubview(pill)
        }
        if project.ahead > 0 {
            let pill = makePill("↑\(project.ahead)", size: 11, weight: .semibold,
                                fg: .secondaryLabelColor,
                                bg: NSColor.labelColor.withAlphaComponent(0.1))
            pill.toolTip = "\(project.ahead) commits ahead of remote"
            statusStack.addArrangedSubview(pill)
        }
        if project.isDirty {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.layer?.cornerRadius = 3
            dot.toolTip = "Uncommitted changes"
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            statusStack.addArrangedSubview(dot)
        }
        let time = makeLabel(Self.relativeFormatter.localizedString(for: item.displayDate, relativeTo: Date()),
                             size: 12, color: .secondaryLabelColor)
        statusStack.addArrangedSubview(time)
        let source = makeSymbolView(project.activitySource.symbol, size: 9.5,
                                    tint: NSColor(project.activitySource.tint))
        source.toolTip = "Last activity via \(project.activitySource.rawValue)"
        statusStack.addArrangedSubview(source)
    }

    private func buildActions() {
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 3
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        func actionButton(symbol: String, tooltip: String, handler: @escaping () -> Void) -> ClosureButton {
            let button = ClosureButton.make(handler: handler)
            button.image = IconCache.symbol(symbol, size: 13)
            button.contentTintColor = .labelColor
            button.toolTip = tooltip
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            button.layer?.cornerRadius = 5
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 27),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            return button
        }

        if project.overleafURL != nil {
            actionsStack.addArrangedSubview(
                actionButton(symbol: "globe", tooltip: "Open on Overleaf") { [store, project] in
                    store.openOverleaf(project)
                })
        }
        if let app = store.effectiveApp(for: project) {
            let button = ClosureButton.make { [store, project] in store.open(project, with: nil) }
            button.image = IconCache.appIcon(app, size: 18)
            button.toolTip = project.lastEditor != nil && store.settings.smartEditor
                ? "Open in \(app.name) (last used here)" : "Open in \(app.name)"
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 27),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            actionsStack.addArrangedSubview(button)
        }
        actionsStack.addArrangedSubview(
            actionButton(symbol: "terminal",
                         tooltip: "Open in \(store.terminalApp?.name ?? "Terminal")") { [store, project] in
                store.openTerminal(project)
            })
        actionsStack.addArrangedSubview(
            actionButton(symbol: "folder", tooltip: "Reveal in Finder") { [store, project] in
                store.reveal(project)
            })
    }

    private func buildDetail(below rowHeight: CGFloat) {
        let detail = NSStackView()
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 0
        detail.translatesAutoresizingMaskIntoConstraints = false

        func detailLine(_ views: [NSView]) {
            let line = NSStackView(views: views)
            line.orientation = .horizontal
            line.spacing = 8
            NSLayoutConstraint.activate([line.heightAnchor.constraint(equalToConstant: 18)])
            detail.addArrangedSubview(line)
        }

        var meta: [NSView] = []
        if let branch = project.gitBranch {
            meta.append(makeSymbolView("arrow.triangle.branch", size: 10, tint: .secondaryLabelColor))
            meta.append(makeLabel(branch, size: 11.5, color: .secondaryLabelColor))
        }
        if let upstream = store.remoteDetails[project.path]?.upstream {
            meta.append(makeLabel("→ \(upstream)", size: 11.5, color: .tertiaryLabelColor))
        }
        if project.isWorktree, let main = project.worktreeOf {
            meta.append(makeLabel("worktree of \((main as NSString).lastPathComponent)",
                                  size: 11.5, color: .systemPurple))
        }
        if project.ahead > 0 {
            meta.append(makeLabel("↑\(project.ahead) unpushed", size: 11.5, color: .secondaryLabelColor))
        }
        if project.isDirty {
            meta.append(makeLabel("● uncommitted changes", size: 11.5, color: .systemOrange))
        }
        detailLine(meta)

        if let subject = project.lastCommitSubject, !subject.isEmpty {
            detailLine([makeLabel("last commit: \(subject)", size: 11.5, color: .tertiaryLabelColor)])
        }
        if project.behind > 0 {
            if let remote = store.remoteDetails[project.path], !remote.incoming.isEmpty {
                for commit in remote.incoming.prefix(4) {
                    let arrow = makeLabel("↓", size: 11.5, weight: .bold, color: .systemBlue)
                    let subject = makeLabel(commit.subject, size: 11.5, color: .systemBlue)
                    let who = makeLabel("— \(commit.author), \(commit.when)", size: 11.5,
                                        color: .secondaryLabelColor)
                    detailLine([arrow, subject, who])
                }
                if project.behind > 4 {
                    detailLine([makeLabel("…and \(project.behind - 4) more remote commits",
                                          size: 11.5, color: .tertiaryLabelColor)])
                }
            } else {
                detailLine([makeLabel(
                    "↓ \(project.behind) new remote commit\(project.behind == 1 ? "" : "s") — loading…",
                    size: 11.5, color: .systemBlue)])
            }
        }

        addSubview(detail)
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: topAnchor, constant: rowHeight + 2),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent + 54),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    // MARK: Hover

    private func updateBackground(hovering: Bool) {
        if isSelected {
            background.layer?.backgroundColor =
                NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            background.layer?.borderWidth = 1
            background.layer?.borderColor =
                NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        } else {
            background.layer?.backgroundColor = hovering
                ? NSColor.labelColor.withAlphaComponent(0.05).cgColor : NSColor.clear.cgColor
            background.layer?.borderWidth = 0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        statusStack.isHidden = true
        actionsStack.isHidden = false
        updateBackground(hovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        statusStack.isHidden = false
        actionsStack.isHidden = true
        updateBackground(hovering: false)
    }
}
