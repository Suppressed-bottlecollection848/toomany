import AppKit
import SwiftUI

enum TimeBucket: Int, Equatable {
    case today, week, month, older

    static func of(_ date: Date) -> TimeBucket {
        let age = Date().timeIntervalSince(date)
        if age < 24 * 3600 { return .today }
        if age < 7 * 24 * 3600 { return .week }
        if age < 30 * 24 * 3600 { return .month }
        return .older
    }

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .older: "Older"
        }
    }
}

/// One row in the launcher list: a project, possibly nested under its main repo.
struct DisplayItem: Identifiable {
    let project: Project
    let depth: Int        // 0 = top level, 1 = worktree under its main repo
    let childCount: Int   // number of worktrees grouped under this row
    let isExpanded: Bool
    let displayDate: Date // group activity (max of own + children) for parents
    let bucket: TimeBucket? // nil while searching (no section headers)
    var id: String { project.id }
}

final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var query = ""
    @Published var filterKind: FilterKind = .all
    @Published var selectedIndex = 0
    @Published var expandedGroups: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "po.expandedGroups") ?? [])
    @Published var remoteDetails: [String: GitClient.RemoteDetail] = [:]
    private var detailRequests = Set<String>()
    @Published var showOlder = false
    @Published var isPinned = UserDefaults.standard.bool(forKey: "po.pinned") {
        didSet { UserDefaults.standard.set(isPinned, forKey: "po.pinned") }
    }
    @Published var isScanning = false
    @Published var isFetching = false
    @Published var focusToken = 0
    @Published var settings: AppSettings {
        didSet { settings.save() }
    }

    let installedApps: [OpenableApp]
    var onHide: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var lastScan: Date?
    private var lastFetch: Date?

    init() {
        var s = AppSettings.load()
        let apps = AppCatalog.detectInstalled()
        installedApps = apps

        func firstAppID(named preferredNames: [String]) -> String? {
            preferredNames.compactMap { name in apps.first { $0.name == name } }.first?.id
        }
        func isInstalled(_ id: String?) -> Bool {
            apps.contains { $0.id == id }
        }

        if !isInstalled(s.defaultAppID) {
            s.defaultAppID = firstAppID(named: ["Cursor", "VS Code", "Zed"]) ?? apps.first?.id
        }
        if !isInstalled(s.terminalAppID) {
            s.terminalAppID = firstAppID(named: ["iTerm2", "Ghostty", "Terminal"])
        }
        settings = s
        projects = CacheStore.loadProjects() // instant stale list; rescan refreshes it
    }

    var defaultApp: OpenableApp? {
        installedApps.first { $0.id == settings.defaultAppID } ?? installedApps.first
    }

    var terminalApp: OpenableApp? {
        installedApps.first { $0.id == settings.terminalAppID }
            ?? installedApps.first { $0.isTerminal }
    }

    var visibleItems: [DisplayItem] { cachedItems().shown }

    /// Top-level entries older than 30 days (hidden until "Show older").
    var olderCount: Int { cachedItems().older }

    // visibleItems is read many times per render pass; rebuild only when an
    // input actually changed (minute granularity covers time-bucket drift).
    private struct ItemsKey: Equatable {
        let query: String
        let filter: FilterKind
        let showOlder: Bool
        let expanded: Set<String>
        let projectsVersion: Int
        let minute: Int
    }

    private var itemsCache: (key: ItemsKey, shown: [DisplayItem], older: Int)?
    private var projectsVersion = 0

    private func cachedItems() -> (shown: [DisplayItem], older: Int) {
        let key = ItemsKey(query: query, filter: filterKind, showOlder: showOlder,
                           expanded: expandedGroups, projectsVersion: projectsVersion,
                           minute: Int(Date().timeIntervalSince1970 / 60))
        if let cache = itemsCache, cache.key == key {
            return (cache.shown, cache.older)
        }
        let built = buildItems()
        itemsCache = (key, built.shown, built.older)
        return built
    }

    private func buildItems() -> (shown: [DisplayItem], older: Int) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = projects.filter { filterKind.matches($0) }

        // Searching shows flat, unsectioned results across all ages.
        if !q.isEmpty {
            var scored = base.compactMap { p in
                Ranker.score(p, query: q).map { (project: p, score: $0) }
            }
            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.project.lastActivity > b.project.lastActivity
            }
            let items = scored.map {
                DisplayItem(project: $0.project, depth: 0, childCount: 0,
                            isExpanded: false, displayDate: $0.project.lastActivity, bucket: nil)
            }
            return (items, 0)
        }

        // The Worktrees chip shows a flat (but still sectioned) list.
        if filterKind == .worktrees {
            var items: [DisplayItem] = []
            var older = 0
            for p in base {
                let bucket = TimeBucket.of(p.lastActivity)
                if bucket == .older {
                    older += 1
                    if !showOlder { continue }
                }
                items.append(DisplayItem(project: p, depth: 0, childCount: 0,
                                         isExpanded: false, displayDate: p.lastActivity, bucket: bucket))
            }
            return (items, older)
        }

        // Group worktrees under their main repo.
        let parents = base.filter { !$0.isWorktree }
        let parentPaths = Set(parents.map(\.path))
        var childrenByParent: [String: [Project]] = [:]
        var orphans: [Project] = []
        for p in base where p.isWorktree {
            if let main = p.worktreeOf, parentPaths.contains(main) {
                childrenByParent[main, default: []].append(p)
            } else {
                orphans.append(p)
            }
        }

        struct Group {
            let head: Project
            let children: [Project]
            let sortDate: Date
        }
        var groups: [Group] = parents.map { parent in
            let kids = (childrenByParent[parent.path] ?? []).sorted { $0.lastActivity > $1.lastActivity }
            return Group(head: parent, children: kids,
                         sortDate: max(parent.lastActivity, kids.first?.lastActivity ?? .distantPast))
        }
        groups.append(contentsOf: orphans.map { Group(head: $0, children: [], sortDate: $0.lastActivity) })
        groups.sort { $0.sortDate > $1.sortDate }

        var items: [DisplayItem] = []
        var older = 0
        for g in groups {
            let bucket = TimeBucket.of(g.sortDate)
            if bucket == .older {
                older += 1
                if !showOlder { continue }
            }
            let expanded = expandedGroups.contains(g.head.path)
            items.append(DisplayItem(project: g.head, depth: 0, childCount: g.children.count,
                                     isExpanded: expanded, displayDate: g.sortDate, bucket: bucket))
            if expanded {
                // Children inherit the parent's bucket so no header splits a group.
                for kid in g.children {
                    items.append(DisplayItem(project: kid, depth: 1, childCount: 0,
                                             isExpanded: false, displayDate: kid.lastActivity, bucket: bucket))
                }
            }
        }
        return (items, older)
    }

    // MARK: Grouping

    func toggleGroup(_ path: String) {
        if expandedGroups.remove(path) == nil { expandedGroups.insert(path) }
        UserDefaults.standard.set(Array(expandedGroups), forKey: "po.expandedGroups")
        clampSelection()
    }

    /// The currently highlighted row, if the selection is in range.
    private var selectedItem: DisplayItem? {
        let items = visibleItems
        return selectedIndex < items.count ? items[selectedIndex] : nil
    }

    /// Right arrow (empty query): expand the selected group.
    func expandSelectedGroup() {
        guard let item = selectedItem else { return }
        if item.childCount > 0, !item.isExpanded { toggleGroup(item.project.path) }
    }

    /// Left arrow (empty query): collapse the selected group, or jump from a
    /// worktree row to its main repo.
    func collapseSelectedGroup() {
        guard let item = selectedItem else { return }
        if item.depth > 0, let main = item.project.worktreeOf {
            if let idx = visibleItems.firstIndex(where: { $0.project.path == main }) {
                selectedIndex = idx
            }
        } else if item.isExpanded {
            toggleGroup(item.project.path)
        }
    }

    func count(for kind: FilterKind) -> Int {
        projects.filter { kind.matches($0) }.count
    }

    // MARK: Lifecycle

    func panelWillShow() {
        focusToken += 1
        query = ""
        selectedIndex = 0
        showOlder = false
        let minutes = settings.refreshMinutes
        if minutes > 0, Self.isStale(lastScan, after: TimeInterval(minutes * 60)) {
            refreshAll()
        }
    }

    /// True when `date` is nil or older than `interval` seconds — used to gate
    /// rescans and fetches so they don't repeat on every panel open.
    private static func isStale(_ date: Date?, after interval: TimeInterval) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > interval
    }

    func refreshAll() {
        let fetchGate = max(30 * 60, TimeInterval(settings.refreshMinutes * 60))
        rescan(thenCheckRemotes: settings.autoFetch && Self.isStale(lastFetch, after: fetchGate))
    }

    func rescan(thenCheckRemotes: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        let snapshot = settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ProjectScanner(settings: snapshot).scan()
            CacheStore.saveProjects(result)
            DispatchQueue.main.async {
                guard let self else { return }
                self.projects = result
                self.projectsVersion += 1
                self.isScanning = false
                self.lastScan = Date()
                self.invalidateRemoteDetails()
                self.clampSelection()
                if thenCheckRemotes { self.checkRemotes() }
            }
        }
    }

    func checkRemotes() {
        guard !isFetching else { return }
        let gitProjects = projects.filter { $0.categories.contains(.git) }
        let fetchPaths = Array(Set(gitProjects.filter(\.hasUpstream).map { $0.worktreeOf ?? $0.path }))
        guard !fetchPaths.isEmpty else { return }
        isFetching = true
        let allGitPaths = gitProjects.map(\.path)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            Parallel.each(fetchPaths.count, limit: 8) { i in
                GitClient.fetch(fetchPaths[i])
            }
            let lock = NSLock()
            var updates: [String: GitClient.RepoStatus] = [:]
            Parallel.each(allGitPaths.count, limit: 24) { i in
                let path = allGitPaths[i]
                let st = ProjectScanner.cheapStatusOnly(path)
                    ? GitClient.statusNoWorktreeScan(path)
                    : GitClient.status(path)
                guard let st else { return }
                lock.lock()
                updates[path] = st
                lock.unlock()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.projects = self.projects.map { p in
                    guard let st = updates[p.path] else { return p }
                    var q = p
                    q.behind = st.behind
                    q.ahead = st.ahead
                    q.isDirty = st.isDirty
                    return q
                }
                self.projectsVersion += 1
                CacheStore.saveProjects(self.projects)
                self.isFetching = false
                self.lastFetch = Date()
                self.invalidateRemoteDetails()
            }
        }
    }

    // MARK: Selection & opening

    func clampSelection() {
        let count = visibleItems.count
        if selectedIndex >= count { selectedIndex = max(0, count - 1) }
    }

    func moveSelection(_ delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    func openSelected(reveal: Bool = false) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let project = items[min(selectedIndex, items.count - 1)].project
        if reveal {
            self.reveal(project)
        } else {
            open(project, with: nil)
        }
    }

    /// The app a plain open (↩ / click) uses: the project's last-used editor
    /// when known and smart-editor is on, otherwise the configured default.
    func effectiveApp(for project: Project) -> OpenableApp? {
        if settings.smartEditor, let editor = project.lastEditor {
            let name = (editor == .cursor) ? "Cursor" : (editor == .vscode) ? "VS Code" : nil
            if let name, let app = installedApps.first(where: { $0.name == name }) {
                return app
            }
        }
        return defaultApp
    }

    func open(_ project: Project, with app: OpenableApp?) {
        guard let target = app ?? effectiveApp(for: project) else { return }
        Opener.open(project, with: target)
        hideIfUnpinned()
    }

    func openTerminal(_ project: Project) {
        guard let term = terminalApp else { return }
        Opener.open(project, with: term)
        hideIfUnpinned()
    }

    func reveal(_ project: Project) {
        Opener.reveal(project)
        hideIfUnpinned()
    }

    func openOverleaf(_ project: Project) {
        guard let url = project.overleafURL else { return }
        NSWorkspace.shared.open(url)
        hideIfUnpinned()
    }

    private func hideIfUnpinned() {
        if !isPinned { onHide?() }
    }

    func setDefaultApp(_ app: OpenableApp) {
        settings.defaultAppID = app.id
    }

    func setTerminalApp(_ app: OpenableApp) {
        settings.terminalAppID = app.id
    }

    // MARK: Remote detail (lazy, for the selected row)

    func requestRemoteDetail(_ project: Project) {
        guard project.categories.contains(.git), project.hasUpstream,
              remoteDetails[project.path] == nil,
              !detailRequests.contains(project.path) else { return }
        detailRequests.insert(project.path)
        let path = project.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail = GitClient.remoteDetail(path)
            DispatchQueue.main.async {
                self?.remoteDetails[path] = detail
                self?.detailRequests.remove(path)
            }
        }
    }

    private func invalidateRemoteDetails() {
        remoteDetails = [:]
        detailRequests = []
    }
}
