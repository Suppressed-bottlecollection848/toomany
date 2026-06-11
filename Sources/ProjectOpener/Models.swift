import AppKit
import SwiftUI

// MARK: - Categories

enum ProjectCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case git, overleaf, claude, codex, worktree

    var symbol: String {
        switch self {
        case .git: "arrow.triangle.branch"
        case .overleaf: "leaf.fill"
        case .claude: "sparkle"
        case .codex: "terminal.fill"
        case .worktree: "arrow.triangle.pull"
        }
    }

    var tint: Color {
        switch self {
        case .git: .gray
        case .overleaf: .green
        case .claude: .orange
        case .codex: .blue
        case .worktree: .purple
        }
    }

    var title: String {
        switch self {
        case .git: "Git"
        case .overleaf: "Overleaf"
        case .claude: "Claude"
        case .codex: "Codex"
        case .worktree: "Worktree"
        }
    }
}

enum ActivitySource: String, Codable, Sendable {
    case git, claude, codex, cursor, vscode, filesystem

    var symbol: String {
        switch self {
        case .git: "arrow.triangle.branch"
        case .claude: "sparkle"
        case .codex: "terminal.fill"
        case .cursor: "cursorarrow"
        case .vscode: "curlybraces"
        case .filesystem: "clock"
        }
    }

    var tint: Color {
        switch self {
        case .git: .gray
        case .claude: .orange
        case .codex: .blue
        case .cursor: .indigo
        case .vscode: .teal
        case .filesystem: .secondary
        }
    }
}

// MARK: - Project kind (detected from folder contents, drives the row icon)

enum ProjectKind: String, Codable, Sendable {
    case lean, latex, swiftPkg, rust, go, node, python, notebook, web, docs, ai

    var symbol: String {
        switch self {
        case .lean: "function"
        case .latex: "doc.text.fill"
        case .swiftPkg: "swift"
        case .rust: "gearshape.fill"
        case .go: "g.square.fill"
        case .node: "hexagon.fill"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .notebook: "text.book.closed.fill"
        case .web: "globe"
        case .docs: "books.vertical.fill"
        case .ai: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .lean: .indigo
        case .latex: .teal
        case .swiftPkg: .orange
        case .rust: Color(red: 0.72, green: 0.43, blue: 0.16)
        case .go: .cyan
        case .node: .green
        case .python: .blue
        case .notebook: Color(red: 0.95, green: 0.55, blue: 0.15)
        case .web: .blue
        case .docs: .brown
        case .ai: .purple
        }
    }
}

// MARK: - Project

struct Project: Identifiable, Hashable, Codable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    var categories: Set<ProjectCategory> = []
    var lastActivity: Date = .distantPast
    var activitySource: ActivitySource = .filesystem
    var gitBranch: String?
    var isWorktree = false
    var worktreeOf: String?
    var hasUpstream = false
    var isDirty = false
    var behind = 0
    var ahead = 0
    var overleafURL: URL?
    var lastCommitSubject: String?
    var lastEditor: ActivitySource? // .cursor or .vscode if a recent window is known
    var kind: ProjectKind?          // detected project type, drives the row icon
    var hasCustomIcon: Bool?        // user-assigned Finder icon (Icon\r present)

    var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Filter chips

enum FilterKind: String, CaseIterable, Identifiable {
    case all, git, overleaf, claude, codex, worktrees, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .git: "Git"
        case .overleaf: "Overleaf"
        case .claude: "Claude"
        case .codex: "Codex"
        case .worktrees: "Worktrees"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .git: "arrow.triangle.branch"
        case .overleaf: "leaf.fill"
        case .claude: "sparkle"
        case .codex: "terminal.fill"
        case .worktrees: "arrow.triangle.pull"
        case .updates: "arrow.down.circle.fill"
        }
    }

    func matches(_ p: Project) -> Bool {
        switch self {
        case .all: true
        case .git: p.categories.contains(.git)
        case .overleaf: p.categories.contains(.overleaf)
        case .claude: p.categories.contains(.claude)
        case .codex: p.categories.contains(.codex)
        case .worktrees: p.isWorktree
        case .updates: p.behind > 0
        }
    }
}

// MARK: - Openable apps

struct OpenableApp: Identifiable, Hashable {
    enum Strategy: Hashable { case editor, terminalOpen, ghostty, warp, finder }

    let id: String
    let name: String
    let strategy: Strategy
    let appURL: URL

    var isTerminal: Bool {
        strategy == .terminalOpen || strategy == .ghostty || strategy == .warp
    }
}

enum AppCatalog {
    static func detectInstalled() -> [OpenableApp] {
        struct Candidate {
            let name: String
            let bundleIDs: [String]
            let paths: [String]
            let strategy: OpenableApp.Strategy
        }
        let candidates: [Candidate] = [
            .init(name: "VS Code", bundleIDs: ["com.microsoft.VSCode"], paths: ["/Applications/Visual Studio Code.app"], strategy: .editor),
            .init(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], paths: ["/Applications/Cursor.app"], strategy: .editor),
            .init(name: "Zed", bundleIDs: ["dev.zed.Zed"], paths: ["/Applications/Zed.app"], strategy: .editor),
            .init(name: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"], paths: ["/Applications/Sublime Text.app"], strategy: .editor),
            .init(name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"], paths: ["/Applications/Windsurf.app"], strategy: .editor),
            .init(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], paths: ["/Applications/Xcode.app"], strategy: .editor),
            .init(name: "Finder", bundleIDs: ["com.apple.finder"], paths: ["/System/Library/CoreServices/Finder.app"], strategy: .finder),
            .init(name: "Terminal", bundleIDs: ["com.apple.Terminal"], paths: ["/System/Applications/Utilities/Terminal.app"], strategy: .terminalOpen),
            .init(name: "iTerm2", bundleIDs: ["com.googlecode.iterm2"], paths: ["/Applications/iTerm.app"], strategy: .terminalOpen),
            .init(name: "Ghostty", bundleIDs: ["com.mitchellh.ghostty"], paths: ["/Applications/Ghostty.app"], strategy: .ghostty),
            .init(name: "Warp", bundleIDs: ["dev.warp.Warp-Stable"], paths: ["/Applications/Warp.app"], strategy: .warp),
        ]

        // An app's identity is its locating bundle ID, or failing that its path.
        func locate(_ candidate: Candidate) -> (id: String, url: URL)? {
            for bundleID in candidate.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    return (bundleID, url)
                }
            }
            for path in candidate.paths where FileManager.default.fileExists(atPath: path) {
                return (path, URL(fileURLWithPath: path))
            }
            return nil
        }

        return candidates.compactMap { candidate in
            guard let found = locate(candidate) else { return nil }
            return OpenableApp(id: found.id, name: candidate.name,
                               strategy: candidate.strategy, appURL: found.url)
        }
    }
}

// MARK: - Opening projects

enum Opener {
    static func open(_ project: Project, with app: OpenableApp) {
        let dirURL = URL(fileURLWithPath: project.path)
        switch app.strategy {
        case .editor, .terminalOpen:
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([dirURL], withApplicationAt: app.appURL, configuration: config)
        case .finder:
            NSWorkspace.shared.open(dirURL)
        case .ghostty:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", "Ghostty", "--args", "--working-directory=\(project.path)"]
            try? process.run()
        case .warp:
            var components = URLComponents(string: "warp://action/new_window")!
            components.queryItems = [URLQueryItem(name: "path", value: project.path)]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }
    }

    static func reveal(_ project: Project) {
        NSWorkspace.shared.selectFile(project.path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Icon cache

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func folderIcon(_ path: String, size: CGFloat = 32) -> NSImage {
        let key = "folder|\(path)|\(Int(size))" as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = (NSWorkspace.shared.icon(forFile: path).copy() as! NSImage)
        img.size = NSSize(width: size, height: size)
        cache.setObject(img, forKey: key)
        return img
    }

    static func appIcon(_ app: OpenableApp, size: CGFloat) -> NSImage {
        let key = "\(app.id)#\(Int(size))" as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = (NSWorkspace.shared.icon(forFile: app.appURL.path).copy() as! NSImage)
        img.size = NSSize(width: size, height: size)
        cache.setObject(img, forKey: key)
        return img
    }

    /// SF Symbol image at a given point size (template; tint via contentTintColor).
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// Row icon: a user-assigned Finder icon wins; otherwise a colored glyph
    /// tile for the detected project kind; otherwise the plain folder icon.
    static func projectIcon(_ project: Project, size: CGFloat) -> NSImage {
        guard project.hasCustomIcon != true, let kind = project.kind else {
            return folderIcon(project.path, size: size)
        }
        let key = "tile|\(kind.rawValue)|\(project.name)|\(Int(size))" as NSString
        if let img = cache.object(forKey: key) { return img }
        let color = tileColor(kind: kind, name: project.name)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.24, yRadius: size * 0.24)
            let light = color.blended(withFraction: 0.18, of: .white) ?? color
            NSGradient(colors: [light, color])?.draw(in: path, angle: -90)
            if let sym = symbol(kind.symbol, size: size * 0.46, weight: .semibold) {
                let tinted = NSImage(size: sym.size, flipped: false) { r in
                    sym.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let r = NSRect(x: (rect.width - sym.size.width) / 2,
                               y: (rect.height - sym.size.height) / 2,
                               width: sym.size.width, height: sym.size.height)
                tinted.draw(in: r)
            }
            return true
        }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Deterministic small hue shift per project name (stable djb2 — Swift's
    /// hashValue is randomized per launch), so two projects of the same kind
    /// get visibly different shades of the same color family.
    static func tileColor(kind: ProjectKind, name: String) -> NSColor {
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        let shift = CGFloat(Int(hash % 7) - 3) * 0.022
        guard let base = NSColor(kind.tint).usingColorSpace(.deviceRGB) else { return NSColor(kind.tint) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var hue = h + shift
        if hue < 0 { hue += 1 }
        if hue > 1 { hue -= 1 }
        return NSColor(hue: hue, saturation: s, brightness: b, alpha: a)
    }
}

// MARK: - Search ranking

enum Ranker {
    static func score(_ project: Project, query: String) -> Int? {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }
        var total = 0
        for t in tokens {
            guard let s = score(name: project.name.lowercased(),
                                path: project.displayPath.lowercased(),
                                token: t) else { return nil }
            total += s
        }
        return total
    }

    private static func score(name: String, path: String, token: String) -> Int? {
        if name == token { return 1000 }
        if name.hasPrefix(token) { return 900 }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(token) }) { return 800 }
        if name.contains(token) { return 700 }
        if isSubsequence(token, of: name) { return 450 }
        if path.contains(token) { return 250 }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.startIndex
        for ch in needle {
            while it != haystack.endIndex, haystack[it] != ch {
                it = haystack.index(after: it)
            }
            if it == haystack.endIndex { return false }
            it = haystack.index(after: it)
        }
        return true
    }
}
