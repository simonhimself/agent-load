import Foundation

/// Matches a Claude Code "brain" to its session (owner, 2026-11-14).
///
/// OpenChamber sessions on a Claude model (provider `claude-code`) run a `claude` CLI process
/// under opencode while they work; it reads and writes the session's folder and keeps its own
/// transcript. opencode stores no mapping from that process to the session, so it is inferred:
///   (a) candidates: sessions on provider claude-code whose directory is the process's cwd,
///       busy ones first (else ones active in the last 10 minutes); exactly one → that session;
///   (b) several: the one whose latest user message equals / contains the latest user message in
///       the brain's transcript (or the other way round);
///   (c) still several: the one that became busy closest to the process start.
/// No candidate, or no text match among several: unmatched ("Claude Code (unmatched)").
public enum BrainMatcher {
    public static let provider = "claude-code"
    public static let recentMs: Int64 = 10 * 60_000

    public static func match(cwd: String, startMs: Int64, transcriptLastUser: String?, sessions: [DBSession],
                             nowMs: Int64, lastUserText: (String) -> String?) -> String? {
        guard !cwd.isEmpty else { return nil }
        let cands = sessions.filter { $0.provider == provider && !$0.directory.isEmpty && sameDir($0.directory, cwd) }
        var pool = cands.filter { SessionListing.isActiveBusy($0, nowMs: nowMs) }
        if pool.isEmpty { pool = cands.filter { nowMs - $0.lastActivity <= recentMs } }
        if pool.count == 1 { return pool[0].id }
        guard pool.count > 1, let mine = transcriptLastUser.map(normalise), mine.count >= 4 else { return nil }
        let byText = pool.filter { s in lastUserText(s.id).map { textMatches(mine, normalise($0)) } ?? false }
        if byText.count <= 1 { return byText.first?.id }
        return byText.min { abs(($0.timeBusy ?? 0) - startMs) < abs(($1.timeBusy ?? 0) - startMs) }?.id
    }

    static func normalise(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Equal, or one contains the start of the other (the plugin may wrap the prompt).
    static func textMatches(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let n = 200
        return a.contains(String(b.prefix(n))) || b.contains(String(a.prefix(n)))
    }
}
