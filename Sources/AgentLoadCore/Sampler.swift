import Foundation

/// Glues the readers, the DB and the classifier together and produces a `Snapshot`.
/// Not thread-safe: call `sample` from one serial background queue.
public final class Sampler {
    private let reader = ProcessReader()
    private let stats = SystemStats()
    private let db: SessionDB
    private let home = NSHomeDirectory()
    private let transcripts = TranscriptStore()

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
        // Terminal harness sessions: their transcripts (title, last user message, last write).
        let infos = transcripts.infos(for: result.harnessGroups)
        return SnapshotBuilder.build(classification: result, totals: totals, now: now, home: home,
                                     notes: notes, dbSessions: dbSessions, transcripts: infos)
    }
}
