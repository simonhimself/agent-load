import Foundation
import SQLite3

/// Read-only lookups in opencode's database (~/.local/share/opencode/opencode.db).
///
/// Safety rules (the DB is live, ~4 GB, WAL mode, written by opencode):
/// - opened with SQLITE_OPEN_READONLY (never writes; not `immutable`, so WAL is honoured)
/// - short single statements in autocommit mode: no transaction is ever held open
/// - short busy timeout; any failure returns nil and the UI falls back to folder names
/// - callers cache results; nothing here runs on every refresh
public final class SessionDB {
    public let path: String
    private var db: OpaquePointer?
    /// Last error text, for --dump.
    public private(set) var lastError: String?

    public init(path: String = NSHomeDirectory() + "/.local/share/opencode/opencode.db") {
        self.path = path
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    private func open() -> OpaquePointer? {
        if let db { return db }
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            lastError = "open failed (\(rc))"
            if let h { sqlite3_close_v2(h) }
            return nil
        }
        sqlite3_busy_timeout(h, 250)
        // Schema check: fail soft if opencode changed its layout.
        guard columnsExist(h, table: "session_v2", ["id", "title", "directory", "parent_id"]),
              columnsExist(h, table: "session_message", ["session_id", "time_created", "data", "type"]) else {
            lastError = "unexpected schema"
            sqlite3_close_v2(h)
            return nil
        }
        db = h
        return h
    }

    private func columnsExist(_ h: OpaquePointer, table: String, _ cols: [String]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        var found = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { found.insert(String(cString: c)) }
        }
        return Set(cols).isSubset(of: found)
    }

    /// Runs one query; `bind` binds parameters, `row` reads each result row.
    private func query(_ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> Void) -> Bool {
        guard let h = open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            lastError = String(cString: sqlite3_errmsg(h)); return false
        }
        defer { sqlite3_finalize(stmt) }   // finalizing ends the implicit read transaction
        bind(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc == SQLITE_DONE { return true }
            lastError = String(cString: sqlite3_errmsg(h)); return false
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    /// Finds the session whose tool call ran `command`, for a shell that started at
    /// `startMs` (ms since 1970). Looks for the exact JSON field `"command":"<escaped>"`
    /// in messages created in [start − 30 min, start + 1 min] and picks the latest message
    /// created at or before the shell start (+5 s clock slack). That resolves identical
    /// commands in two sessions and ignores sessions that merely quoted it later.
    /// If nothing matches, retries over the previous 24 h (long-running agent turns).
    public func sessionForCommand(_ command: String, startMs: Int64) -> SessionInfo? {
        let needle = JSONEscape.commandNeedle(command)
        for back in [Int64(30 * 60_000), Int64(24 * 3_600_000)] {
            if let s = findMessage(needle: needle, from: startMs - back, to: startMs + 60_000, notAfter: startMs + 5_000) {
                return session(id: s)
            }
        }
        return nil
    }

    private func findMessage(needle: String, from: Int64, to: Int64, notAfter: Int64) -> String? {
        // Prefer the latest message at or before the shell start; else the earliest after it.
        let sql = """
            SELECT session_id FROM session_message
            WHERE time_created BETWEEN ?1 AND ?2 AND instr(data, ?3) > 0
            ORDER BY (time_created <= ?4) DESC,
                     CASE WHEN time_created <= ?4 THEN -time_created ELSE time_created END
            LIMIT 1
            """
        var found: String?
        _ = query(sql, bind: { s in
            sqlite3_bind_int64(s, 1, from)
            sqlite3_bind_int64(s, 2, to)
            sqlite3_bind_text(s, 3, needle, -1, Self.transient)
            sqlite3_bind_int64(s, 4, notAfter)
        }, row: { s in found = Self.text(s, 0) })
        return found
    }

    public func session(id: String) -> SessionInfo? {
        var info: SessionInfo?
        _ = query("SELECT id, title, directory, parent_id FROM session_v2 WHERE id = ?1",
                  bind: { sqlite3_bind_text($0, 1, id, -1, Self.transient) },
                  row: { s in
                      info = SessionInfo(id: Self.text(s, 0) ?? id, title: Self.text(s, 1) ?? "",
                                         directory: Self.text(s, 2) ?? "", parentID: Self.text(s, 3))
                  })
        return info
    }

    /// Sessions for the listing rule (SessionListing): every non-archived session updated in
    /// the last 7 days, plus their ancestors (recursive, via parent_id). For sessions flagged
    /// busy, `lastActivity` also looks at their newest message (index
    /// session_message_session_time_created_id_idx), for the stale-flag check.
    /// One short read-only statement; nil if the DB cannot be read.
    public func listingSessions(nowMs: Int64) -> [DBSession]? {
        let sql = """
            WITH RECURSIVE keep(id) AS (
                SELECT id FROM session_v2 WHERE time_archived IS NULL AND time_updated > ?1
                UNION
                SELECT p.parent_id FROM session_v2 p JOIN keep k ON p.id = k.id WHERE p.parent_id IS NOT NULL)
            SELECT s.id, s.title, s.directory, s.parent_id, s.time_busy, s.time_idle,
                   CASE WHEN s.time_busy > coalesce(s.time_idle, 0)
                        THEN max(s.time_updated, coalesce((SELECT max(m.time_created) FROM session_message m
                                                           WHERE m.session_id = s.id), 0))
                        ELSE s.time_updated END
            FROM session_v2 s WHERE s.id IN keep AND s.time_archived IS NULL
            """
        var out: [DBSession] = []
        let ok = query(sql, bind: { sqlite3_bind_int64($0, 1, nowMs - 7 * 86_400_000) }, row: { s in
            func int(_ i: Int32) -> Int64? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_int64(s, i) }
            out.append(DBSession(id: Self.text(s, 0) ?? "", title: Self.text(s, 1) ?? "", directory: Self.text(s, 2) ?? "",
                                 parentID: Self.text(s, 3), timeBusy: int(4), timeIdle: int(5), lastActivity: int(6) ?? 0))
        })
        return ok ? out : nil
    }

    /// Self-check for `--verify-db`: takes the last `limit` shell tool calls, re-escapes each
    /// command with `JSONEscape` and checks that the needle is found in its own message.
    /// Returns (checked, matched, examples of failures, number of commands containing quotes/newlines).
    public func verifyEscaping(limit: Int) -> (checked: Int, matched: Int, failures: [String], tricky: Int) {
        let sql = """
            SELECT m.data, json_extract(j.value, '$.state.input.command')
            FROM (SELECT data FROM session_message WHERE type = 'assistant' AND instr(data, '"name":"shell"') > 0
                  ORDER BY time_created DESC LIMIT ?1) AS m, json_each(m.data, '$.content') AS j
            WHERE json_extract(j.value, '$.type') = 'tool' AND json_extract(j.value, '$.name') = 'shell'
              AND json_extract(j.value, '$.state.input.command') IS NOT NULL
            """
        var checked = 0, matched = 0, tricky = 0
        var failures: [String] = []
        _ = query(sql, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }, row: { s in
            guard let data = Self.text(s, 0), let cmd = Self.text(s, 1) else { return }
            checked += 1
            if cmd.contains("\"") || cmd.contains("\n") || cmd.contains("\\") { tricky += 1 }
            if data.contains(JSONEscape.commandNeedle(cmd)) { matched += 1 } else if failures.count < 5 { failures.append(String(cmd.prefix(120))) }
        })
        return (checked, matched, failures, tricky)
    }

    /// Session whose messages of the last 24 h mention `folder` most (for orphaned processes).
    public func sessionForFolder(_ folder: String, nowMs: Int64) -> SessionInfo? {
        let sql = """
            SELECT session_id, count(*) AS n FROM session_message
            WHERE time_created >= ?1 AND instr(data, ?2) > 0
            GROUP BY session_id ORDER BY n DESC, max(time_created) DESC LIMIT 1
            """
        var found: String?
        _ = query(sql, bind: { s in
            sqlite3_bind_int64(s, 1, nowMs - 24 * 3_600_000)
            sqlite3_bind_text(s, 2, JSONEscape.escape(folder), -1, Self.transient)
        }, row: { s in found = Self.text(s, 0) })
        return found.flatMap { session(id: $0) }
    }
}
