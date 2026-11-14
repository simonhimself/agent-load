import Foundation

/// Which sessions get a row (owner's rule, 2026-11-13): every session whose work is not
/// completed, whether it is using the machine, thinking, or waiting.
///
/// A session is listed if ANY of:
///   1. it has running processes attributed to it (any CPU/memory, even 0%), or
///   2. OpenChamber marks it busy (`time_busy > coalesce(time_idle, 0)`, not archived) and the
///      flag is not stale, or
///   3. a descendant session (via `parent_id`, any depth) qualifies under 1 or 2; it is then
///      shown as "waiting for N sessions".
///
/// Stale busy flag: a busy session with no processes whose last sign of life (newest message
/// or session update, or the busy time itself) is more than 12 h old is treated as not active.
public enum SessionListing {
    public static let staleAfterMs: Int64 = 12 * 3_600_000

    /// Rule 2 for one session.
    public static func isActiveBusy(_ s: DBSession, nowMs: Int64) -> Bool {
        guard s.flaggedBusy, let busy = s.timeBusy else { return false }
        return nowMs - max(busy, s.lastActivity) <= staleAfterMs
    }

    /// Sessions run by OpenChamber: those carrying OpenChamber's metadata key themselves or
    /// through any ancestor (older sub-sessions lack the key, their root session has it).
    /// The listing query includes every ancestor, so the walk sees the whole chain.
    public static func openChamberIDs(_ db: [DBSession]) -> Set<String> {
        let byID = Dictionary(db.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [String: Bool] = [:]
        func isOC(_ id: String, depth: Int) -> Bool {
            if let m = memo[id] { return m }
            guard let s = byID[id], depth < 64 else { return false }
            let r = s.openChamberOwn || (s.parentID.map { isOC($0, depth: depth + 1) } ?? false)
            memo[id] = r
            return r
        }
        return Set(db.map(\.id).filter { isOC($0, depth: 0) })
    }

    /// Builds the final, sorted session rows from the process-based rows and the DB sessions.
    public static func rows(processRows: [SessionRow], db: [DBSession], nowMs: Int64, home: String,
                            byMemory: Bool = false) -> [SessionRow] {
        let byID = Dictionary(db.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ocIDs = openChamberIDs(db)
        var rows = processRows
        var rowIDs = Set(processRows.map(\.id))

        // Active sessions and when they became active (ms).
        var activeSince: [String: Int64] = [:]
        var activeTitle: [String: String] = [:]
        var parentOf: [String: String] = [:]
        for s in db { if let p = s.parentID { parentOf[s.id] = p } }
        for r in processRows {
            activeSince[r.id] = nowMs - Int64(r.runningSeconds) * 1000
            activeTitle[r.id] = r.title
            if let p = r.parentID, parentOf[r.id] == nil { parentOf[r.id] = p }
        }
        for s in db where isActiveBusy(s, nowMs: nowMs) {
            let since = s.timeBusy ?? nowMs
            activeSince[s.id] = min(activeSince[s.id] ?? since, since)
            activeTitle[s.id] = s.title
            if !rowIDs.contains(s.id) {
                var row = dbRow(s, state: .thinking, activity: "thinking", sinceMs: since, nowMs: nowMs, home: home)
                row.harness = ocIDs.contains(s.id) ? .openChamber : .openCode
                rows.append(row)
                rowIDs.insert(s.id)
            }
        }

        // Rule 3: every non-active ancestor of an active session waits on it.
        var waitingOn: [String: [String]] = [:]   // ancestor id -> active descendant ids
        for id in activeSince.keys.sorted() {
            var seen = Set<String>([id])
            var cur = parentOf[id]
            while let anc = cur, !seen.contains(anc) {
                seen.insert(anc)
                if activeSince[anc] == nil { waitingOn[anc, default: []].append(id) }
                cur = parentOf[anc]
            }
        }
        for (anc, kids) in waitingOn where !rowIDs.contains(anc) {
            guard let s = byID[anc] else { continue }   // unknown or archived ancestor: no row
            let ordered = kids.sorted { (activeSince[$0] ?? 0) < (activeSince[$1] ?? 0) }
            let n = ordered.count
            var row = dbRow(s, state: .waiting, activity: n == 1 ? "waiting for 1 session" : "waiting for \(n) sessions",
                            sinceMs: ordered.compactMap { activeSince[$0] }.min() ?? nowMs, nowMs: nowMs, home: home)
            row.waitingFor = ordered.compactMap { activeTitle[$0] }
            row.harness = ocIDs.contains(anc) ? .openChamber : .openCode
            rows.append(row)
            rowIDs.insert(anc)
        }
        return sorted(rows, byMemory: byMemory)
    }

    /// Row for a session without processes. Grey line: `<project> · <state> · <time>`;
    /// chat folders (~/.config/openchamber/chats) have no folder part and no click target.
    static func dbRow(_ s: DBSession, state: SessionState, activity: String, sinceMs: Int64, nowMs: Int64, home: String) -> SessionRow {
        let project = SnapshotBuilder.projectName(directory: s.directory, home: home)
        return SessionRow(id: s.id, title: s.title.isEmpty ? (project ?? "Session") : s.title, project: project,
                          folderName: project ?? "", folderPath: project == nil ? "" : s.directory,
                          activity: activity, runningSeconds: Int(max(0, nowMs - sinceMs) / 1000),
                          cpuPercent: 0, memBytes: 0, kinds: [], processes: [],
                          state: state, parentID: s.parentID)
    }

    /// Sorted by whatever is running short: CPU first (then memory) normally, memory first
    /// (then CPU) when memory is the problem (amber/red memory; owner, 2026-11-14), so the top
    /// row is the biggest contributor. Rows that show 0% / 0.0 GB: thinking, then waiting,
    /// then sleeping process rows; newest first within each.
    public static func sorted(_ rows: [SessionRow], byMemory: Bool = false) -> [SessionRow] {
        func group(_ r: SessionRow) -> Int {
            if r.cpuPercent >= 0.5 { return 0 }                  // shows as ≥ 1%
            if byMemory && r.memBytes >= 50_000_000 { return 0 } // shows as ≥ 0.1 GB
            switch r.state { case .thinking: return 1; case .waiting: return 2; case .processes: return 3 }
        }
        return rows.sorted { a, b in
            let ga = group(a), gb = group(b)
            if ga != gb { return ga < gb }
            if ga == 0 {
                return byMemory ? (Double(a.memBytes), a.cpuPercent) > (Double(b.memBytes), b.cpuPercent)
                                : (a.cpuPercent, Double(a.memBytes)) > (b.cpuPercent, Double(b.memBytes))
            }
            return a.runningSeconds < b.runningSeconds          // newest first
        }
    }
}
