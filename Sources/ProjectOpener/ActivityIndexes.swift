import Foundation

// MARK: - Cache helpers

enum CacheStore {
    static let dir: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectOpener", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func loadJSON(_ name: String) -> [String: String] {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func saveJSON(_ dict: [String: String], _ name: String) {
        let url = dir.appendingPathComponent(name)
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadProjects() -> [Project] {
        let url = dir.appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: url),
              let projects = try? JSONDecoder().decode([Project].self, from: data) else { return [] }
        return projects.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func saveProjects(_ projects: [Project]) {
        let url = dir.appendingPathComponent("projects.json")
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Claude path encoding/decoding

enum PathCodec {
    /// Claude Code encodes a project path by replacing every non-alphanumeric char with "-".
    static func encode(_ path: String) -> String {
        String(path.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
    }

    /// Decode an encoded name back to a real path, filesystem-guided: at each
    /// "/" boundary, list the actual child directories and match their encoded
    /// names against the remaining string. Longer matches are tried first so
    /// "TNLean-blueprint" prefers a sibling over "TNLean/blueprint" when both exist.
    static func decode(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        let fm = FileManager.default
        var budget = 4000

        func rec(_ idx: String.Index, _ dir: String) -> String? {
            budget -= 1
            if budget <= 0 { return nil }
            guard let children = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
            let remaining = encoded[idx...]
            let ranked = children
                .map { (name: $0, enc: encode($0)) }
                .filter { !$0.enc.isEmpty && remaining.hasPrefix($0.enc) }
                .sorted { $0.enc.count > $1.enc.count }
            for child in ranked {
                let childPath = dir == "/" ? "/" + child.name : dir + "/" + child.name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue else { continue }
                let nextIdx = encoded.index(idx, offsetBy: child.enc.count)
                if nextIdx == encoded.endIndex { return childPath }
                if encoded[nextIdx] == "-" {
                    if let r = rec(encoded.index(after: nextIdx), childPath) { return r }
                }
            }
            return nil
        }
        return rec(encoded.index(after: encoded.startIndex), "/")
    }
}

// MARK: - Claude Code activity (~/.claude/projects)

enum ClaudeIndex {
    /// Returns decoded project path -> newest session activity date.
    static func load() -> [String: Date] {
        let fm = FileManager.default
        let base = NSHomeDirectory() + "/.claude/projects"
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return [:] }

        var result: [String: Date] = [:]
        for dirName in dirs where !dirName.hasPrefix(".") {
            let dirPath = base + "/" + dirName
            guard let newest = newestEntryDate(in: dirPath),
                  let path = PathCodec.decode(dirName) else { continue }
            result[path] = max(result[path] ?? .distantPast, newest)
        }
        return result
    }

    private static func newestEntryDate(in dirPath: String) -> Date? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else { return nil }
        var newest: Date?
        for name in names {
            guard let attrs = try? fm.attributesOfItem(atPath: dirPath + "/" + name),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            newest = max(newest ?? modified, modified)
        }
        return newest
    }
}

// MARK: - Cursor / VS Code recent workspaces

enum EditorIndex {
    /// Returns folder path -> (last time a Cursor/VS Code window for it was
    /// active, which editor). Derived from each workspace's storage dir:
    /// workspace.json names the folder, state.vscdb's mtime tracks activity.
    static func load() -> [String: (date: Date, source: ActivitySource)] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let editors: [(storageDir: String, source: ActivitySource)] = [
            (home + "/Library/Application Support/Cursor/User/workspaceStorage", .cursor),
            (home + "/Library/Application Support/Code/User/workspaceStorage", .vscode),
        ]

        var result: [String: (date: Date, source: ActivitySource)] = [:]
        for (storageDir, source) in editors {
            guard let hashes = try? fm.contentsOfDirectory(atPath: storageDir) else { continue }
            for hash in hashes {
                let wsDir = storageDir + "/" + hash
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: wsDir + "/workspace.json")),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let folderURI = obj["folder"] as? String,
                      folderURI.hasPrefix("file://"),
                      let url = URL(string: folderURI) else { continue }
                let attrs = (try? fm.attributesOfItem(atPath: wsDir + "/state.vscdb"))
                    ?? (try? fm.attributesOfItem(atPath: wsDir))
                guard let date = attrs?[.modificationDate] as? Date else { continue }
                let path = url.path
                if let existing = result[path], existing.date >= date { continue }
                result[path] = (date, source)
            }
        }
        return result
    }
}

// MARK: - Codex activity (~/.codex/sessions)

enum CodexIndex {
    /// Sessions older than this don't influence activity times; skipping their
    /// (sessions/YYYY/MM/…) directories avoids stat'ing thousands of old files.
    private static let maxAge: TimeInterval = 365 * 24 * 3600

    /// Returns cwd -> newest session activity date.
    static func load() -> [String: Date] {
        let home = NSHomeDirectory()
        var files: [(path: String, mtime: Date)] = []
        for dir in [home + "/.codex/sessions", home + "/.codex/archived_sessions"] {
            files.append(contentsOf: sessionFiles(under: dir))
        }
        guard !files.isEmpty else { return [:] }

        var cwdCache = CacheStore.loadJSON("codex-cwds.json")
        let lock = NSLock()
        var cacheDirty = false
        var result: [String: Date] = [:]

        let uncached = files.enumerated().filter { cwdCache[$0.element.path] == nil }
        if !uncached.isEmpty {
            var newEntries = [(String, String)?](repeating: nil, count: uncached.count)
            DispatchQueue.concurrentPerform(iterations: uncached.count) { i in
                let filePath = uncached[i].element.path
                let cwd = readCwd(filePath) ?? ""
                newEntries[i] = (filePath, cwd)
            }
            for case let (filePath, cwd)? in newEntries {
                cwdCache[filePath] = cwd
            }
            cacheDirty = true
        }

        for f in files {
            guard let cwd = cwdCache[f.path], !cwd.isEmpty else { continue }
            lock.lock()
            result[cwd] = max(result[cwd] ?? .distantPast, f.mtime)
            lock.unlock()
        }

        if cacheDirty { CacheStore.saveJSON(cwdCache, "codex-cwds.json") }
        return result
    }

    /// Collects .jsonl session files, skipping date-named subdirectories
    /// (YYYY, then MM) entirely once they fall outside `maxAge`.
    private static func sessionFiles(under root: String) -> [(path: String, mtime: Date)] {
        let fm = FileManager.default
        let cutoff = Calendar.current.dateComponents([.year, .month],
                                                     from: Date(timeIntervalSinceNow: -maxAge))
        let cutYear = cutoff.year ?? 0
        let cutMonth = cutoff.month ?? 0

        var results: [(String, Date)] = []
        func collectAll(in dir: String) {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                results.append((url.path, m))
            }
        }

        guard let years = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for year in years {
            let yearPath = root + "/" + year
            guard let y = Int(year) else {
                collectAll(in: yearPath) // unknown layout — take everything
                continue
            }
            if y < cutYear { continue }
            guard let months = try? fm.contentsOfDirectory(atPath: yearPath) else { continue }
            for month in months {
                if y == cutYear, let m = Int(month), m < cutMonth { continue }
                collectAll(in: yearPath + "/" + month)
            }
        }
        return results
    }

    private static let cwdRegex = try! NSRegularExpression(pattern: #""cwd"\s*:\s*"([^"]+)""#)

    /// Reads the head of a session file and extracts the session_meta cwd.
    private static func readCwd(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 256 * 1024), !data.isEmpty else { return nil }

        // Prefer parsing the full first JSON line if we captured it.
        if let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data.prefix(upTo: nl)
            if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                if let payload = obj["payload"] as? [String: Any], let cwd = payload["cwd"] as? String {
                    return cwd
                }
                if let cwd = obj["cwd"] as? String { return cwd }
            }
        }
        // Fallback: regex over the head chunk.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = cwdRegex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
