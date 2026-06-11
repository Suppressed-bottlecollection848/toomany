import Foundation

// MARK: - Settings

struct AppSettings: Equatable, Sendable {
    var roots: [String] = ["~/Local"]
    var maxDepth: Int = 3
    var excludedNames: [String] = ["node_modules", "build", "dist", "out", "target", "__pycache__", "venv", "Pods", "DerivedData"]
    var defaultAppID: String?
    var terminalAppID: String?
    var hotkeyPreset: String = "ctrl-opt-space"
    var autoFetch: Bool = true
    var smartEditor: Bool = true // open with the last-used editor when known
    var refreshMinutes: Int = 15 // auto-rescan when panel opens, at most this often (0 = manual)

    private static let d = UserDefaults.standard

    static func load() -> AppSettings {
        var s = AppSettings()
        if let roots = d.stringArray(forKey: "po.roots"), !roots.isEmpty { s.roots = roots }
        let depth = d.integer(forKey: "po.maxDepth")
        if depth > 0 { s.maxDepth = depth }
        if let ex = d.stringArray(forKey: "po.excludedNames") { s.excludedNames = ex }
        s.defaultAppID = d.string(forKey: "po.defaultAppID")
        s.terminalAppID = d.string(forKey: "po.terminalAppID")
        if let hk = d.string(forKey: "po.hotkeyPreset") { s.hotkeyPreset = hk }
        if d.object(forKey: "po.autoFetch") != nil { s.autoFetch = d.bool(forKey: "po.autoFetch") }
        if d.object(forKey: "po.smartEditor") != nil { s.smartEditor = d.bool(forKey: "po.smartEditor") }
        if d.object(forKey: "po.refreshMinutes") != nil { s.refreshMinutes = d.integer(forKey: "po.refreshMinutes") }
        return s
    }

    func save() {
        Self.d.set(roots, forKey: "po.roots")
        Self.d.set(maxDepth, forKey: "po.maxDepth")
        Self.d.set(excludedNames, forKey: "po.excludedNames")
        Self.d.set(defaultAppID, forKey: "po.defaultAppID")
        Self.d.set(terminalAppID, forKey: "po.terminalAppID")
        Self.d.set(hotkeyPreset, forKey: "po.hotkeyPreset")
        Self.d.set(autoFetch, forKey: "po.autoFetch")
        Self.d.set(smartEditor, forKey: "po.smartEditor")
        Self.d.set(refreshMinutes, forKey: "po.refreshMinutes")
    }

    var expandedRoots: [String] {
        roots.map { NSString(string: $0.trimmingCharacters(in: .whitespaces)).expandingTildeInPath }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Scanner

final class ProjectScanner {
    private let settings: AppSettings
    private let fm = FileManager.default
    private let home = NSHomeDirectory()

    private struct Seed {
        var path: String
        var isGit: Bool
        var isWorktree = false
        var worktreeOf: String?
        var branch: String?
        var claudeDate: Date?
        var codexDate: Date?
        var editorDate: Date?
        var editorSource: ActivitySource?
    }

    private var seeds: [String: Seed] = [:]
    private lazy var excluded = Set(settings.excludedNames)
    private lazy var rootSet = Set(settings.expandedRoots.map(Self.norm))

    init(settings: AppSettings) {
        self.settings = settings
    }

    static func norm(_ path: String) -> String {
        var p = (NSString(string: path).expandingTildeInPath as NSString).standardizingPath
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        return p
    }

    /// Paths on file-provider volumes (iCloud Drive) where stat'ing the working
    /// tree is extremely slow; git operations there must avoid worktree scans.
    static func isSlowVolume(_ path: String) -> Bool {
        path.hasPrefix(NSHomeDirectory() + "/Library/Mobile Documents")
    }

    /// Detects what kind of project lives at `path` from marker files in its
    /// root — priority-ordered, first match wins. Drives the row icon.
    static func detectKind(_ path: String, isOverleaf: Bool) -> ProjectKind? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        var lower = Set<String>()
        var exts = Set<String>()
        for n in names {
            let l = n.lowercased()
            lower.insert(l)
            let e = (l as NSString).pathExtension
            if !e.isEmpty { exts.insert(e) }
        }
        if lower.contains("lakefile.lean") || lower.contains("lean-toolchain") || exts.contains("lean") { return .lean }
        if isOverleaf || exts.contains("tex") { return .latex }
        if lower.contains("package.swift") || exts.contains("xcodeproj") { return .swiftPkg }
        if lower.contains("cargo.toml") { return .rust }
        if lower.contains("go.mod") { return .go }
        if lower.contains("package.json") { return .node }
        if lower.contains("pyproject.toml") || lower.contains("requirements.txt")
            || lower.contains("setup.py") || lower.contains("environment.yml") || exts.contains("py") { return .python }
        if exts.contains("ipynb") { return .notebook }
        if lower.contains("index.html") { return .web }
        if lower.contains("mkdocs.yml") || lower.contains("book.toml") || lower.contains("_quarto.yml") { return .docs }
        if lower.contains("claude.md") || lower.contains("agents.md") { return .ai }
        return nil
    }

    /// Repos where a full `git status` working-tree scan isn't worth it:
    /// slow volumes, plus Codex's ephemeral worktree checkouts whose cold
    /// indexes make every status a multi-second rehash.
    static func cheapStatusOnly(_ path: String) -> Bool {
        isSlowVolume(path) || path.contains("/.codex/worktrees/")
    }

    private static let verbose = ProcessInfo.processInfo.environment["PO_VERBOSE"] != nil
    private var phaseStart = Date()
    private func mark(_ label: String) {
        guard Self.verbose else { return }
        print(String(format: "  [%.2fs] %@", Date().timeIntervalSince(phaseStart), label))
        phaseStart = Date()
    }

    func scan() -> [Project] {
        phaseStart = Date()
        let claudeIndex = ClaudeIndex.load()
        mark("claude index (\(claudeIndex.count))")
        let codexIndex = CodexIndex.load()
        mark("codex index (\(codexIndex.count))")

        // 1. Walk the configured roots.
        for root in settings.expandedRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
            walk(URL(fileURLWithPath: root), depth: 1)
        }
        mark("walk (\(seeds.count) seeds)")

        // 2. Attribute Claude/Codex activity, discovering projects outside roots.
        attribute(codexIndex, to: \.codexDate)
        attribute(claudeIndex, to: \.claudeDate)
        // Editor activity only enriches projects we already know about —
        // one-off folders opened in an editor shouldn't join the list.
        for (path, info) in EditorIndex.load() {
            guard let owner = ownerProject(for: Self.norm(path), createIfMissing: false) else { continue }
            if let current = seeds[owner]!.editorDate, current >= info.date { continue }
            seeds[owner]!.editorDate = info.date
            seeds[owner]!.editorSource = info.source
        }
        mark("activity attribution (\(seeds.count) seeds)")

        // 3. Expand git worktrees of every repo we know about.
        expandWorktrees()
        mark("worktree expansion (\(seeds.count) seeds)")

        // 4. Enrich seeds concurrently and build projects. The work is almost
        // entirely waiting on git child processes, so go wider than the cores.
        let all = Array(seeds.values)
        var projects = [Project?](repeating: nil, count: all.count)
        Parallel.each(all.count, limit: 24) { i in
            let t = Date()
            projects[i] = self.buildProject(from: all[i])
            if Self.verbose, Date().timeIntervalSince(t) > 1.0 {
                print(String(format: "    slow enrich %.2fs  %@", Date().timeIntervalSince(t), all[i].path))
            }
        }
        mark("enrichment")

        return projects.compactMap { $0 }.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: Walk

    /// A git Seed for a directory known to contain `.git`, classifying it as a
    /// linked worktree when `.git` is a pointer file rather than a real directory.
    private func gitSeed(at path: String, gitIsDir: Bool) -> Seed {
        var seed = Seed(path: path, isGit: true)
        if !gitIsDir {
            seed.isWorktree = true
            seed.worktreeOf = GitClient.mainRepoOfWorktree(path)
        }
        return seed
    }

    private func walk(_ dir: URL, depth: Int) {
        guard depth <= settings.maxDepth else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return }
        for child in children {
            guard let vals = try? child.resourceValues(forKeys: Set(keys)),
                  vals.isDirectory == true, vals.isSymbolicLink != true else { continue }
            let name = child.lastPathComponent
            if excluded.contains(name) { continue }
            let path = Self.norm(child.path)

            var gitIsDir: ObjCBool = false
            if fm.fileExists(atPath: path + "/.git", isDirectory: &gitIsDir) {
                seeds[path] = gitSeed(at: path, gitIsDir: gitIsDir.boolValue)
                continue // do not descend into repositories
            }
            walk(child, depth: depth + 1)
        }
    }

    // MARK: Activity attribution

    /// Folds an index of `path -> date` into the owning seeds, keeping the newest
    /// date in the given field. May create seeds for projects outside the roots.
    private func attribute(_ index: [String: Date], to field: WritableKeyPath<Seed, Date?>) {
        for (path, date) in index {
            guard let owner = ownerProject(for: Self.norm(path)) else { continue }
            seeds[owner]![keyPath: field] = max(seeds[owner]![keyPath: field] ?? .distantPast, date)
        }
    }

    /// Finds (or creates) the project that owns `path`: the path itself if known,
    /// the nearest known ancestor, the enclosing git repository, or the directory itself.
    private func ownerProject(for path: String, createIfMissing: Bool = true) -> String? {
        guard path != "/", path != home, !rootSet.contains(path) else { return nil }
        if seeds[path] != nil { return path }

        // Nearest already-known ancestor.
        var anc = path
        while anc.contains("/"), anc != "/", anc != home {
            if seeds[anc] != nil { return anc }
            anc = (anc as NSString).deletingLastPathComponent
        }
        guard createIfMissing else { return nil }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        // The directory itself, or its enclosing repo, becomes a new seed.
        var candidate = path
        while candidate != "/", candidate != home {
            var gitIsDir: ObjCBool = false
            if fm.fileExists(atPath: candidate + "/.git", isDirectory: &gitIsDir) {
                if rootSet.contains(candidate) { return nil }
                seeds[candidate] = gitSeed(at: candidate, gitIsDir: gitIsDir.boolValue)
                return candidate
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }

        seeds[path] = Seed(path: path, isGit: false)
        return path
    }

    // MARK: Worktrees

    private func expandWorktrees() {
        let repoPaths = seeds.values.filter { $0.isGit }.map { $0.worktreeOf ?? $0.path }
        let uniqueMains = Array(Set(repoPaths))

        let lock = NSLock()
        var discovered: [(path: String, branch: String?, main: String)] = []
        Parallel.each(uniqueMains.count, limit: 24) { i in
            let main = uniqueMains[i]
            guard FileManager.default.fileExists(atPath: main) else { return }
            // Cheap no-spawn pre-check: linked worktrees always have entries
            // under <gitdir>/worktrees. Most repos have none — skip the spawn.
            guard let gitDir = GitClient.gitCommonDir(main),
                  let registered = try? FileManager.default.contentsOfDirectory(atPath: gitDir + "/worktrees"),
                  !registered.isEmpty else { return }
            let entries = GitClient.worktrees(main)
            guard !entries.isEmpty else { return }
            let mainPath = entries.first(where: { $0.isMain })?.path ?? main
            for e in entries where !e.isMain {
                lock.lock()
                discovered.append((Self.norm(e.path), e.branch, Self.norm(mainPath)))
                lock.unlock()
            }
        }

        for d in discovered {
            guard fm.fileExists(atPath: d.path) else { continue }
            // Make sure the main repo is listed too, so the group has a parent.
            if seeds[d.main] == nil, !rootSet.contains(d.main) {
                var gitIsDir: ObjCBool = false
                if fm.fileExists(atPath: d.main + "/.git", isDirectory: &gitIsDir), gitIsDir.boolValue {
                    seeds[d.main] = Seed(path: d.main, isGit: true)
                }
            }
            if var existing = seeds[d.path] {
                existing.isWorktree = true
                existing.worktreeOf = d.main
                existing.branch = existing.branch ?? d.branch
                seeds[d.path] = existing
            } else {
                seeds[d.path] = Seed(path: d.path, isGit: true, isWorktree: true,
                                     worktreeOf: d.main, branch: d.branch)
            }
        }
    }

    // MARK: Enrichment

    private func buildProject(from seed: Seed) -> Project? {
        guard fm.fileExists(atPath: seed.path) else { return nil }
        var p = Project(path: seed.path, name: (seed.path as NSString).lastPathComponent)

        var gitDate: Date?
        if seed.isGit {
            p.categories.insert(.git)
            if let head = GitClient.headCommit(seed.path) {
                gitDate = head.date
                p.lastCommitSubject = head.subject
            }
            let st = Self.cheapStatusOnly(seed.path)
                ? GitClient.statusNoWorktreeScan(seed.path)
                : GitClient.status(seed.path)
            if let st {
                p.gitBranch = seed.branch ?? st.branch
                p.isDirty = st.isDirty
                p.hasUpstream = st.hasUpstream
                p.behind = st.behind
                p.ahead = st.ahead
            } else {
                p.gitBranch = seed.branch
            }
            for url in GitClient.remoteURLs(seed.path) where url.contains("overleaf") {
                p.categories.insert(.overleaf)
                if let id = url.split(separator: "/").last {
                    p.overleafURL = URL(string: "https://www.overleaf.com/project/\(id)")
                }
                break
            }
            if seed.isWorktree {
                p.isWorktree = true
                p.worktreeOf = seed.worktreeOf
                p.categories.insert(.worktree)
            }
        }
        if seed.claudeDate != nil { p.categories.insert(.claude) }
        if seed.codexDate != nil { p.categories.insert(.codex) }
        p.lastEditor = seed.editorSource
        p.hasCustomIcon = fm.fileExists(atPath: seed.path + "/Icon\r")
        p.kind = Self.detectKind(seed.path, isOverleaf: p.categories.contains(.overleaf))

        let fsDate = (try? fm.attributesOfItem(atPath: seed.path))?[.modificationDate] as? Date

        var best: (date: Date, source: ActivitySource) = (.distantPast, .filesystem)
        func consider(_ date: Date?, _ source: ActivitySource) {
            if let date, date > best.date { best = (date, source) }
        }
        consider(fsDate, .filesystem)
        consider(gitDate, .git)
        consider(seed.editorDate, seed.editorSource ?? .filesystem)
        consider(seed.codexDate, .codex)
        consider(seed.claudeDate, .claude)
        p.lastActivity = best.date
        p.activitySource = best.source

        return p
    }
}
