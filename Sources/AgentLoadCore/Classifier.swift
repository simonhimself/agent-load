import Foundation

/// Assigns every process to exactly one bucket. Pure logic: all system access comes in via
/// the `Environment` closures, so tests can feed a fixture process tree.
///
/// ORDER MATTERS, because on this machine almost everything descends from OpenChamber:
///   0. terminal harness sessions: a Claude Code, Codex or Pi CLI with no opencode process
///      among its ancestors, and ALL its descendants (its shells, tests, browsers, MCP servers)
///   1. session shell subtrees (a `<shell> -c <command>` whose parent is an agent host:
///      `opencode serve`, the `opencode-pty daemon`, or a `claude` CLI process; the shell
///      and ALL its descendants are that session's work)
///   2. `claude` processes (+ their non-session descendants, e.g. MCP servers)
///   3. opencode server / opencode service (+ their non-session helpers: opencode-pty,
///      caffeinate, zombies)
///   4. OpenChamber app (anything under /OpenChamber.app/ plus leftover descendants), then the
///      Claude desktop app: every process in Claude.app or whose responsible app is Claude.app,
///      which includes the Virtualization.framework VM Claude starts for its local agent work
///      (VMs of other apps, e.g. Docker or Lima, have their own responsible process), then Cua
///      (Cua Spaces.app, its runtime under ~/.cua and the VM that runtime starts)
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
        /// Home folder (Cua's runtime lives in ~/.cua).
        public var home: String = NSHomeDirectory()

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
        /// Process-tree signal for the harness: a shell of this session runs under the
        /// `opencode serve` that OpenChamber.app started.
        public var underOpenChamber = false
    }

    /// A terminal harness session (Claude Code, Codex or Pi started on its own).
    public struct HarnessGroup {
        public var harness: Harness
        /// The outermost harness process (e.g. Codex's node wrapper, not its native child).
        public var root: ProcInfo
        /// Root and all its descendants.
        public var procs: [ProcInfo]
        /// The programs it runs: command shells (`zsh -c …`) and their descendants.
        public var commands: [ProcInfo]
        /// Working directory of the root process ("" if unknown).
        public var cwd: String
        public init(harness: Harness, root: ProcInfo, procs: [ProcInfo], commands: [ProcInfo], cwd: String) {
            self.harness = harness; self.root = root; self.procs = procs; self.commands = commands; self.cwd = cwd
        }
    }

    public struct Result {
        public var sessions: [SessionGroup] = []
        /// Terminal harness sessions (shown only while working; see SnapshotBuilder).
        public var harnessGroups: [HarnessGroup] = []
        public var claude: [ProcInfo] = []
        /// Number of `claude` CLI processes (the "×N"; descendants are not counted).
        public var claudeCount = 0
        public var server: [ProcInfo] = []
        public var service: [ProcInfo] = []
        public var openChamber: [ProcInfo] = []
        /// Claude desktop app: main, helpers and its VM ("Claude app" in Agent tools).
        public var claudeApp: [ProcInfo] = []
        /// Cua: Cua Spaces.app, its daemon, its Lima/Colima runtime in ~/.cua and its VM ("Cua").
        public var cua: [ProcInfo] = []
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

    /// A process of the Claude desktop app: inside Claude.app, or a helper outside the bundle
    /// (e.g. the `com.apple.Virtualization.VirtualMachine` XPC service running its VM) whose
    /// responsible process is Claude.app.
    public static func isClaudeApp(_ p: ProcInfo) -> Bool {
        bundleName(p.path) == "Claude" || (bundleName(p.path) == nil && bundleName(p.responsiblePath) == "Claude")
    }

    /// A process of Cua (owner, 2026-11-14): inside Cua Spaces.app; or its runtime, i.e. an
    /// executable under ~/.cua/ (Lima/Colima `limactl`) or a command whose first word points
    /// there (the `ssh: ~/.cua/…/ssh.sock [mux]` connection to its VM); or a helper outside any
    /// bundle whose responsible process is one of those (the Virtualization.framework VM, whose
    /// responsible process is Cua's `limactl`). Lima/Colima installs elsewhere are not Cua.
    public static func isCua(_ p: ProcInfo, home: String) -> Bool {
        let root = home + "/.cua/"
        func cuaPath(_ path: String) -> Bool { bundleName(path) == "Cua Spaces" || path.hasPrefix(root) }
        if cuaPath(p.path) { return true }
        if bundleName(p.path) == nil, let a0 = p.argv.first, a0.contains(root) { return true }
        return bundleName(p.path) == nil && cuaPath(p.responsiblePath)
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
        func addToSession(info: SessionInfo?, fallbackFolder: String, procs: [ProcInfo], underOpenChamber: Bool = false) {
            let folder = sessionFolder(procs, env: env) ?? fallbackFolder
            let id = info?.id ?? "folder:\(folder)"
            if groups[id] == nil {
                groups[id] = SessionGroup(info: info, id: id, procs: [], folderPath: folder)
                groupOrder.append(id)
            }
            groups[id]!.procs += procs
            if groups[id]!.folderPath.isEmpty { groups[id]!.folderPath = folder }
            if underOpenChamber { groups[id]!.underOpenChamber = true }
        }
        var pending: [ProcInfo] = []

        // 0. Terminal harness sessions. Taken before everything else so their shells are not
        //    looked up in opencode's DB and their programs are not filed under the terminal app.
        //    A harness with an opencode ancestor stays where it was (step 1/2); one below another
        //    harness is part of that harness's session.
        func ancestors(_ p: ProcInfo) -> [ProcInfo] {
            var out: [ProcInfo] = []
            var cur = byPid[p.ppid]
            var guardN = 0
            while let a = cur, a.pid > 1, guardN < 64 { out.append(a); cur = byPid[a.ppid]; guardN += 1 }
            return out
        }
        for p in procs.sorted(by: { $0.startMicros < $1.startMicros }) where !assigned.contains(p.pid) {
            guard let h = HarnessDetect.terminalHarness(p) else { continue }
            let anc = ancestors(p)
            if anc.contains(where: HarnessDetect.isOpencodeProcess) { continue }
            if anc.contains(where: { HarnessDetect.terminalHarness($0) != nil }) { continue }
            let sub = takeSubtree(p.pid)
            // Two-sample rule, as for session shells: a harness seen once (e.g. `claude --version`)
            // makes no row.
            guard env.wasSeenBefore(p.key) else { pending += sub; continue }
            result.harnessGroups.append(HarnessGroup(harness: h, root: p, procs: sub,
                                                     commands: commandProcs(sub, root: p.pid), cwd: env.cwd(p)))
        }

        // 1. Session shell subtrees. Shells seen for the first time are taken out too (so
        //    they don't inflate the opencode server row) but go to "everything else".
        let shells = procs.filter { p in
            guard let parent = byPid[p.ppid], isAgentHost(parent) else { return false }
            return shellCommand(p) != nil
        }.sorted { $0.startMicros < $1.startMicros }
        for sh in shells where !assigned.contains(sh.pid) {
            let sub = takeSubtree(sh.pid)
            guard env.wasSeenBefore(sh.key) else { pending += sub; continue }
            let info = env.sessionForShell(sh, shellCommand(sh) ?? "")
            // Process-tree signal for OpenChamber vs OpenCode: the shell's host is the
            // `opencode serve` whose parent is OpenChamber.app.
            let host = byPid[sh.ppid]
            let underOC = host.map { isOpencodeServe($0) && !isOpencodeService($0)
                && (byPid[$0.ppid]?.path.contains("/OpenChamber.app/") ?? false) } ?? false
            addToSession(info: info, fallbackFolder: env.cwd(sh), procs: sub, underOpenChamber: underOC)
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

        // 4b. Claude desktop app (an agent tool, not an "other app").
        for p in procs where !assigned.contains(p.pid) && isClaudeApp(p) {
            assigned.insert(p.pid)
            result.claudeApp.append(p)
        }

        // 4c. Cua (an agent tool: computer-use sandboxes in its own VM).
        for p in procs where !assigned.contains(p.pid) && isCua(p, home: env.home) {
            assigned.insert(p.pid)
            result.cua.append(p)
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

    /// The programs a harness runs: its command shells and their descendants (not the harness
    /// itself and not its long-running helpers such as MCP servers).
    static func commandProcs(_ sub: [ProcInfo], root: Int32) -> [ProcInfo] {
        let byPid = Dictionary(sub.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return sub.filter { p in
            var cur: ProcInfo? = p
            while let c = cur, c.pid != root {
                if HarnessDetect.isCommandShell(c) { return true }
                cur = byPid[c.ppid]
            }
            return false
        }
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
