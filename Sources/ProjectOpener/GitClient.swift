import Foundation

extension StringProtocol {
    /// The remainder after `prefix`, or nil if the string doesn't start with it.
    /// Handy for parsing the line-prefixed output of `git status --porcelain`.
    func dropPrefix(_ prefix: String) -> SubSequence? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum GitClient {
    @discardableResult
    static func run(_ args: [String], cwd: String? = nil, timeout: TimeInterval = 15) -> CommandResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oConnectTimeout=5"
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        do { try p.run() } catch { return nil }

        var outData = Data()
        var errData = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        readers.wait()

        return CommandResult(
            status: p.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func firstLine(_ r: CommandResult?) -> String? {
        guard let r, r.status == 0 else { return nil }
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Date and subject of the HEAD commit, in one call.
    static func headCommit(_ path: String) -> (date: Date, subject: String)? {
        guard let s = firstLine(run(["log", "-1", "--format=%ct%x09%s"], cwd: path)) else { return nil }
        let parts = s.split(separator: "\t", maxSplits: 1)
        guard let t = TimeInterval(parts[0]) else { return nil }
        return (Date(timeIntervalSince1970: t), parts.count > 1 ? String(parts[1]) : "")
    }

    struct IncomingCommit: Hashable {
        let hash: String
        let author: String
        let subject: String
        let when: String // relative, e.g. "2 hours ago"
    }

    struct RemoteDetail {
        var upstream: String?
        var incoming: [IncomingCommit] = []
    }

    /// Upstream name and who did what on the remote that HEAD lacks
    /// (object-db only — safe on slow volumes). Run after a fetch for fresh data.
    static func remoteDetail(_ path: String) -> RemoteDetail {
        var detail = RemoteDetail()
        detail.upstream = firstLine(run(["rev-parse", "--abbrev-ref", "@{u}"], cwd: path))
        if let r = run(["log", "--format=%h%x09%an%x09%s%x09%cr", "-8", "HEAD..@{u}"],
                       cwd: path, timeout: 10), r.status == 0 {
            for line in r.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
                guard parts.count >= 4 else { continue }
                detail.incoming.append(IncomingCommit(hash: parts[0], author: parts[1],
                                                      subject: parts[2], when: parts[3]))
            }
        }
        return detail
    }

    struct RepoStatus {
        var branch: String?
        var hasUpstream = false
        var ahead = 0
        var behind = 0
        var isDirty = false
    }

    /// One call for branch, upstream, ahead/behind (vs last fetch) and dirty state.
    static func status(_ path: String) -> RepoStatus? {
        guard let r = run(["status", "--porcelain=v2", "--branch", "-unormal"], cwd: path, timeout: 15),
              r.status == 0 else { return nil }
        var st = RepoStatus()
        for line in r.stdout.split(separator: "\n") {
            if let head = line.dropPrefix("# branch.head ") {
                st.branch = (head == "(detached)") ? nil : String(head)
            } else if line.hasPrefix("# branch.upstream ") {
                st.hasUpstream = true
            } else if let ab = line.dropPrefix("# branch.ab ") {
                for field in ab.split(separator: " ") {
                    if field.hasPrefix("+") { st.ahead = Int(field.dropFirst()) ?? 0 }
                    if field.hasPrefix("-") { st.behind = Int(field.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                st.isDirty = true
            }
        }
        return st
    }

    /// Cheap status for repos on slow volumes (iCloud): branch from the HEAD
    /// file, ahead/behind from the object database — no working-tree stats.
    static func statusNoWorktreeScan(_ path: String) -> RepoStatus {
        var st = RepoStatus()
        if let gitDir = gitCommonDir(path) {
            // For linked worktrees HEAD lives in the per-worktree gitdir, but
            // those don't occur on iCloud in practice; common HEAD is fine.
            if let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) {
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if let branch = trimmed.dropPrefix("ref: refs/heads/") {
                    st.branch = String(branch)
                }
            }
        }
        if let r = run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], cwd: path, timeout: 10),
           r.status == 0 {
            let parts = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count == 2 {
                st.hasUpstream = true
                st.behind = Int(parts[0]) ?? 0
                st.ahead = Int(parts[1]) ?? 0
            }
        }
        return st
    }

    /// The repository's common .git directory, resolving worktree/submodule
    /// `.git` pointer files and `commondir` indirection. No process spawn.
    static func gitCommonDir(_ path: String) -> String? {
        let dotGit = path + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        var gitDir: String
        if isDir.boolValue {
            gitDir = dotGit
        } else {
            guard let content = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  content.hasPrefix("gitdir:") else { return nil }
            let g = content.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = g.hasPrefix("/") ? g : (path as NSString).appendingPathComponent(g)
        }
        if let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = c.hasPrefix("/") ? c : (gitDir as NSString).appendingPathComponent(c)
        }
        return (gitDir as NSString).standardizingPath
    }

    /// Remote URLs read directly from the git config file. No process spawn.
    static func remoteURLs(_ path: String) -> [String] {
        guard let gitDir = gitCommonDir(path),
              let cfg = try? String(contentsOfFile: gitDir + "/config", encoding: .utf8) else { return [] }
        var urls: [String] = []
        var inRemote = false
        for raw in cfg.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inRemote = line.hasPrefix("[remote ")
            } else if inRemote, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                urls.append(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return urls
    }

    static func fetch(_ path: String) {
        _ = run(["fetch", "--quiet", "--no-recurse-submodules"], cwd: path, timeout: 25)
    }

    struct WorktreeEntry {
        let path: String
        let branch: String?
        let isMain: Bool
    }

    static func worktrees(_ path: String) -> [WorktreeEntry] {
        guard let r = run(["worktree", "list", "--porcelain"], cwd: path, timeout: 10),
              r.status == 0 else { return [] }
        var entries: [WorktreeEntry] = []
        var curPath: String?
        var curBranch: String?
        var prunable = false
        var isFirst = true

        func flush() {
            if let p = curPath, !prunable {
                entries.append(WorktreeEntry(path: p, branch: curBranch, isMain: isFirst))
                isFirst = false
            } else if curPath != nil {
                isFirst = false
            }
            curPath = nil
            curBranch = nil
            prunable = false
        }

        for line in r.stdout.components(separatedBy: "\n") {
            if line.isEmpty { flush(); continue }
            if let path = line.dropPrefix("worktree ") {
                curPath = String(path)
            } else if let branch = line.dropPrefix("branch refs/heads/") {
                curBranch = String(branch)
            } else if line.hasPrefix("prunable") {
                prunable = true
            }
        }
        flush()
        return entries
    }

    /// For a linked worktree whose `.git` is a file ("gitdir: /main/.git/worktrees/x"),
    /// returns the main repository path.
    static func mainRepoOfWorktree(_ path: String) -> String? {
        let gitFile = path + "/.git"
        guard let content = try? String(contentsOfFile: gitFile, encoding: .utf8),
              content.hasPrefix("gitdir:") else { return nil }
        let gitdir = content.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }
}
