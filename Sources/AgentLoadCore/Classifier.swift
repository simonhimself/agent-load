import Foundation

/// Assigns every process to exactly one bucket. Pure logic: all system access comes in via
/// the `Environment` closures, so tests can feed a fixture process tree.
///
/// ORDER MATTERS, because on this machine almost everything descends from OpenChamber:
///   1. session shell subtrees (a `<shell> -c <command>` whose parent is an agent host:
///      `opencode serve`, the `opencode-pty daemon`, or a `claude` CLI process; the shell
///      and ALL its descendants are that session's work)
///   2. `claude` processes (+ their non-session descendants, e.g. MCP servers)
///   3. opencode server / opencode service (+ their non-session helpers: opencode-pty,
///      caffeinate, zombies)
///   4. OpenChamber app (anything under /OpenChamber.app/ plus leftover descendants)
///   5. orphans (re-parented to launchd) whose cwd is in a `*-wt/<name>` worktree folder
///      → the session that mentions that folder most in the DB
///   6. other apps grouped by .app bundle name (mds / mdworker → "Spotlight indexing")
///   7. everything else (unassigned)
public enum Classifier {

    public struct Environment {
        /// Session that ran this shell command (nil = unknown / DB unavailable).
        public var sessionForShell: (ProcInfo, String) -> SessionInfo?
        /// Session owning a worktree folder (nil = unknown).
        public var sessionForFolder: (String) -> SessionInfo?
        /// Current working directory of a process ("" if unknown). Called lazily.
        public var cwd: (ProcInfo) -> String
        /// True if this process was already present in the previous sample. Session shells
        /// and orphans only create rows once seen twice (avoids flicker from 2-second commands).
        public var wasSeenBefore: (ProcKey) -> Bool
        /// Our own uid; orphans of other users are never session work.
        public var uid: UInt32

        public init(sessionForShell: @escaping (ProcInfo, String) -> SessionInfo?,
                    sessionForFolder: @escaping (String) -> SessionInfo?,
                    cwd: @escaping (ProcInfo) -> String,
                    wasSeenBefore: @escaping (ProcKey) -> Bool,
                    uid: UInt32) {
            self.sessionForShell = sessionForShell; self.sessionForFolder = sessionForFolder
            self.cwd = cwd; self.wasSeenBefore = wasSeenBefore; self.uid = uid
        }
    }

    /// One session's processes (several shells of the same session are merged).
    public struct SessionGroup {
        public var info: SessionInfo?
        /// Key used for merging: session id, or "folder:<cwd>" without DB info.
        public var id: String
        public var procs: [ProcInfo]
        /// Folder the session's programs run in (worktree if any).
        public var folderPath: String
    }

    public struct Result {
        public var sessions: [SessionGroup] = []
        public var claude: [ProcInfo] = []
        /// Number of `claude` CLI processes (the "×N"; descendants are not counted).
        public var claudeCount = 0
        public var server: [ProcInfo] = []
        public var service: [ProcInfo] = []
        public var openChamber: [ProcInfo] = []
        /// App display name → processes.
        public var apps: [String: [ProcInfo]] = [:]
        public var unassigned: [ProcInfo] = []
    }

    // MARK: - Process recognisers

    public static func isOpencodeServe(_ p: ProcInfo) -> Bool {
        (p.exeName == "opencode" || p.name == "opencode") && p.argv.contains("serve")
    }
    public static func isOpencodeService(_ p: ProcInfo) -> Bool { isOpencodeServe(p) && p.argv.contains("--service") }
    public static func isPtyDaemon(_ p: ProcInfo) -> Bool { p.exeName == "opencode-pty" || p.name == "opencode-pty" }
    public static func isClaude(_ p: ProcInfo) -> Bool {
        // ~/.local/bin/claude is a symlink; proc_pidpath resolves it to …/claude/versions/<v>.
        if p.name == "claude" || p.exeName == "claude" { return true }
        if let a0 = p.argv.first, (a0 as NSString).lastPathComponent == "claude" { return true }
        return p.path.contains("/claude/versions/")
    }
    /// Processes that spawn agent session shells.
    public static func isAgentHost(_ p: ProcInfo) -> Bool { isOpencodeServe(p) || isPtyDaemon(p) || isClaude(p) }

    /// `/bin/zsh +o nomatch -c <command>` → `<command>`; nil if not a `-c` shell.
    public static func shellCommand(_ p: ProcInfo) -> String? {
        guard Activity.shells.contains(p.exeName), let i = p.argv.firstIndex(of: "-c"), i + 1 < p.argv.count else { return nil }
        return p.argv[i + 1]
    }

    /// `/Users/x/dev/my-app-wt/wiki-w14/sub/dir` → (`wiki-w14`, `/Users/x/dev/my-app-wt/wiki-w14`).
    public static func worktree(of path: String) -> (name: String, path: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        for i in 0..<(parts.count - 1) where parts[i].hasSuffix("-wt") && parts[i].count > 3 && !parts[i + 1].isEmpty {
            return (String(parts[i + 1]), parts[0...(i + 1)].joined(separator: "/"))
        }
        return nil
    }

    /// Display name for a non-agent process, or nil if it is not part of a named app.
    public static func appName(_ p: ProcInfo) -> String? {
        let spotlight: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "mdbulkimport"]
        if spotlight.contains(p.exeName) || spotlight.contains(p.name) { return "Spotlight indexing" }
        // Outermost .app bundle in the path: /Applications/Firefox.app/Contents/MacOS/plugin-container → "Firefox".
        // Helpers outside any bundle (e.g. Safari's WebKit WebContent XPC service) count for
        // the app responsible for them.
        // Exception: helpers OpenChamber is responsible for (stray agent programs that lost
        // their parent) are not an "app" row; per docs/design.md they are Everything else.
        if let own = bundleName(p.path) { return own }
        let resp = bundleName(p.responsiblePath)
        return resp == "OpenChamber" ? nil : resp
    }

    static func bundleName(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }

    // MARK: - Classification

    public static func classify(_ procs: [ProcInfo], env: Environment) -> Result {
        var byPid: [Int32: ProcInfo] = [:]
        var children: [Int32: [Int32]] = [:]
        for p in procs {
            byPid[p.pid] = p
            if p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }
        }
        var assigned = Set<Int32>()
        var result = Result()

        /// All not-yet-assigned descendants of `root` (root included), stopping at assigned ones.
        func takeSubtree(_ root: Int32) -> [ProcInfo] {
            var out: [ProcInfo] = []
            var stack = [root]
            while let pid = stack.popLast() {
                guard !assigned.contains(pid), let p = byPid[pid] else { continue }
                assigned.insert(pid)
                out.append(p)
                stack.append(contentsOf: children[pid] ?? [])
            }
            return out
        }

        var groups: [String: SessionGroup] = [:]
        var groupOrder: [String] = []
        func addToSession(info: SessionInfo?, fallbackFolder: String, procs: [ProcInfo]) {
            let folder = sessionFolder(procs, env: env) ?? fallbackFolder
            let id = info?.id ?? "folder:\(folder)"
            if groups[id] == nil {
                groups[id] = SessionGroup(info: info, id: id, procs: [], folderPath: folder)
                groupOrder.append(id)
            }
            groups[id]!.procs += procs
            if groups[id]!.folderPath.isEmpty { groups[id]!.folderPath = folder }
        }

        // 1. Session shell subtrees. Shells seen for the first time are taken out too (so
        //    they don't inflate the opencode server row) but go to "everything else".
        let shells = procs.filter { p in
            guard let parent = byPid[p.ppid], isAgentHost(parent) else { return false }
            return shellCommand(p) != nil
        }.sorted { $0.startMicros < $1.startMicros }
        var pending: [ProcInfo] = []
        for sh in shells where !assigned.contains(sh.pid) {
            let sub = takeSubtree(sh.pid)
            guard env.wasSeenBefore(sh.key) else { pending += sub; continue }
            let info = env.sessionForShell(sh, shellCommand(sh) ?? "")
            addToSession(info: info, fallbackFolder: env.cwd(sh), procs: sub)
        }

        // 2. claude CLI processes and their non-session descendants.
        for p in procs where isClaude(p) && !assigned.contains(p.pid) {
            result.claudeCount += 1
            result.claude += takeSubtree(p.pid)
        }

        // 3. opencode serve (server vs --service) and their remaining helpers.
        for p in procs where isOpencodeServe(p) && !assigned.contains(p.pid) {
            if isOpencodeService(p) { result.service += takeSubtree(p.pid) } else { result.server += takeSubtree(p.pid) }
        }
        // A pty daemon whose parent is gone/unknown still belongs to the service.
        for p in procs where isPtyDaemon(p) && !assigned.contains(p.pid) { result.service += takeSubtree(p.pid) }

        // 4. OpenChamber app: main + helpers (by bundle path), and their leftover descendants.
        for p in procs where p.path.contains("/OpenChamber.app/") && !assigned.contains(p.pid) {
            result.openChamber += takeSubtree(p.pid)
        }

        // 5. Orphans in a worktree folder.
        for p in procs where p.ppid == 1 && p.uid == env.uid && !assigned.contains(p.pid) && !p.isZombie {
            guard let wt = worktree(of: env.cwd(p)), env.wasSeenBefore(p.key) else { continue }
            let info = env.sessionForFolder(wt.path)
            addToSession(info: info, fallbackFolder: wt.path, procs: takeSubtree(p.pid))
        }

        // 6. Named apps.
        for p in procs where !assigned.contains(p.pid) {
            if let name = appName(p) {
                assigned.insert(p.pid)
                result.apps[name, default: []].append(p)
            }
        }

        // 7. Everything else.
        //    (Pending first-sight shells were marked assigned in step 1 so no other bucket
        //    took them; they are added back here.)
        result.unassigned = procs.filter { !assigned.contains($0.pid) } + pending
        result.sessions = groupOrder.compactMap { groups[$0] }
        return result
    }

    /// Folder a session works in: the most common worktree among its processes' cwds,
    /// else the most common cwd of its non-shell processes, else nil.
    static func sessionFolder(_ procs: [ProcInfo], env: Environment) -> String? {
        var wtCount: [String: Int] = [:]
        var cwdCount: [String: Int] = [:]
        for p in procs where !p.isZombie {
            let c = env.cwd(p)
            guard !c.isEmpty, c != "/" else { continue }
            if let wt = worktree(of: c) { wtCount[wt.path, default: 0] += 1 }
            if Classifier.shellCommand(p) == nil { cwdCount[c, default: 0] += 1 }
        }
        if let best = wtCount.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { return best.key }
        if let best = cwdCount.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { return best.key }
        return nil
    }
}
