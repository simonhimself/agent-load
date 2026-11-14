import Foundation

/// Glues the readers, the DB and the classifier together and produces a `Snapshot`.
/// Not thread-safe: call `sample` from one serial background queue.
public final class Sampler {
    private let reader = ProcessReader()
    private let stats = SystemStats()
    private let db: SessionDB
    private let home = NSHomeDirectory()
    private let transcripts = TranscriptStore()
    /// Claude Code brain → session id, per process (pid, start). Only matches are kept; an
    /// unmatched brain is tried again on the next refresh (its session may become busy).
    private var brainCache: [ProcKey: String] = [:]
    /// Inferred worktree per session id: looked up again only when the session changed
    /// (its last activity) and at most every 60 s.
    private struct WorktreeGuess { var activity: Int64; var at: Date; var path: String? }
    private var worktreeCache: [String: WorktreeGuess] = [:]
    /// Wall time of the worktree lookups in the last refresh (for --dump).
    public private(set) var lastWorktreeMs: Double = 0

    /// Keys present in the previous sample (two-sample rule for session shells and orphans).
    private var previousKeys = Set<ProcKey>()

    private struct Cached { var info: SessionInfo?; var at: Date }
    /// Session lookups per shell (pid, start time). Never re-queried while the shell lives,
    /// except negative results, retried after `negativeRetry`.
    private var shellCache: [ProcKey: Cached] = [:]
    /// Session lookups per worktree folder (orphans).
    private var folderCache: [String: Cached] = [:]
    private let negativeRetry: TimeInterval = 120
    /// Wall time of the last listing query (for --dump / --bench).
    public private(set) var lastListingQueryMs: Double = 0

    public init(dbPath: String? = nil) {
        db = dbPath.map { SessionDB(path: $0) } ?? SessionDB()
    }

    /// One refresh. `includeOtherUsers` adds a `ps` call for root/other-user processes
    /// (Spotlight etc.); only needed while the dropdown is visible.
    public func sample(includeOtherUsers: Bool, now: Date = Date()) -> Snapshot {
        let procs = reader.sample(includeOtherUsers: includeOtherUsers)
        let totals = stats.read()
        let myUID = reader.myUID

        var cwdCache: [Int32: String] = [:]
        let prev = previousKeys
        let env = Classifier.Environment(
            sessionForShell: { [unowned self] shell, command in
                if let c = shellCache[shell.key], c.info != nil || now.timeIntervalSince(c.at) < negativeRetry { return c.info }
                let info = db.sessionForCommand(command, startMs: shell.startMicros / 1000)
                shellCache[shell.key] = Cached(info: info, at: now)
                return info
            },
            sessionForFolder: { [unowned self] folder in
                if let c = folderCache[folder], c.info != nil || now.timeIntervalSince(c.at) < negativeRetry { return c.info }
                let info = db.sessionForFolder(folder, nowMs: Int64(now.timeIntervalSince1970 * 1000))
                folderCache[folder] = Cached(info: info, at: now)
                return info
            },
            cwd: { p in
                guard p.uid == myUID, !p.isZombie else { return "" }
                if let c = cwdCache[p.pid] { return c }
                let c = ProcessReader.cwd(p.pid)
                cwdCache[p.pid] = c
                return c
            },
            wasSeenBefore: { prev.contains($0) },
            uid: myUID)

        let result = Classifier.classify(procs, env: env)
        previousKeys = Set(procs.map(\.key))
        // Forget cache entries of processes that are gone.
        shellCache = shellCache.filter { previousKeys.contains($0.key) }

        // Sessions that are busy or waiting in OpenChamber (listing rule). One short query per
        // refresh (~ms); on failure the list falls back to process-based rows only.
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let dbSessions = db.listingSessions(nowMs: nowMs) ?? []
        lastListingQueryMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

        var notes: [String] = []
        if let e = db.lastError { notes.append("opencode DB: \(e)") }
        notes.append(String(format: "listing query %.1f ms, %d sessions read", lastListingQueryMs, dbSessions.count))
        // Claude Code brains → their sessions (BrainMatcher).
        let live = Set(result.claudeGroups.map(\.root.key))
        brainCache = brainCache.filter { live.contains($0.key) }
        var userTexts: [String: String?] = [:]
        var brains: [ProcKey: String] = [:]
        for g in result.claudeGroups {
            if let sid = brainCache[g.root.key] { brains[g.root.key] = sid; continue }
            let mine = transcripts.brainLastUser(root: g.root, cwd: g.cwd)
            let sid = BrainMatcher.match(cwd: g.cwd, startMs: g.root.startMicros / 1000, transcriptLastUser: mine,
                                         sessions: dbSessions, nowMs: nowMs) { id in
                if let t = userTexts[id] { return t }
                let t = self.db.lastUserText(sessionID: id)
                userTexts[id] = t
                return t
            }
            if let sid { brainCache[g.root.key] = sid; brains[g.root.key] = sid }
        }

        // Terminal harness sessions: their transcripts (title, last user message, last write).
        let infos = transcripts.infos(for: result.harnessGroups)
        var snap = SnapshotBuilder.build(classification: result, totals: totals, now: now, home: home,
                                         notes: notes, dbSessions: dbSessions, transcripts: infos, brains: brains)

        // Worktrees of rows whose programs don't show one (thinking, waiting, or programs outside
        // a worktree), from the session's own recent messages (WorktreeInference).
        let activity = Dictionary(dbSessions.map { ($0.id, $0.lastActivity) }, uniquingKeysWith: { a, _ in a })
        let need = snap.sessions.filter(WorktreeInference.needsLookup).map(\.id)
        worktreeCache = worktreeCache.filter { need.contains($0.key) }
        let w0 = DispatchTime.now().uptimeNanoseconds
        var worktrees: [String: String] = [:]
        for id in need {
            let act = activity[id] ?? 0
            if let c = worktreeCache[id], c.activity == act || now.timeIntervalSince(c.at) < 60 {
                if let p = c.path { worktrees[id] = p }
                continue
            }
            let path = WorktreeInference.pick(db.recentMessageData(sessionID: id))
            worktreeCache[id] = WorktreeGuess(activity: act, at: now, path: path)
            if let path { worktrees[id] = path }
        }
        lastWorktreeMs = Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e6
        snap.sessions = WorktreeInference.apply(snap.sessions, worktrees: worktrees)
        snap.notes.append(String(format: "worktree lookups %.1f ms", lastWorktreeMs))
        return snap
    }
}
