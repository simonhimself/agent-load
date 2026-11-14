import Foundation

/// The worktree a session works in when none of its programs shows it (owner, 2026-11-14).
///
/// Workers run in git worktrees (`<repo>-wt/<name>`), but a thinking or waiting session has no
/// programs, and its DB directory is the main checkout. So the worktree is inferred from the
/// session's own recent messages: count the paths matching `/<repo>-wt/<name>` (the pattern
/// Classifier.worktree uses) and take the most frequent one if it has at least 3 mentions and at
/// least 60% of all worktree mentions; otherwise none. The folder is not checked for existence:
/// a stat inside ~/Documents could raise macOS's folder-privacy prompt (a stale guess only
/// makes the click do nothing).
public enum WorktreeInference {
    public static let minMentions = 3
    public static let minShare = 0.6

    static let pathRegex = try! NSRegularExpression(pattern: "/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+-wt/[A-Za-z0-9._-]+")

    /// Most mentioned worktree folder (absolute path up to the worktree name), or nil.
    public static func pick(_ texts: [String]) -> String? {
        var counts: [String: Int] = [:]
        for t in texts where t.contains("-wt/") {
            let ns = t as NSString
            for m in pathRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                guard let wt = Classifier.worktree(of: ns.substring(with: m.range)) else { continue }
                counts[wt.path, default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              best.value >= minMentions, Double(best.value) >= minShare * Double(total) else { return nil }
        return best.key
    }

    /// Rows that need the lookup: DB sessions (not terminal harness or folder-only rows) whose
    /// folder part is not already a worktree from their programs.
    public static func needsLookup(_ r: SessionRow) -> Bool {
        !r.id.hasPrefix("harness:") && !r.id.hasPrefix("folder:") && Classifier.worktree(of: r.folderPath) == nil
    }

    /// Puts each inferred worktree (session id → path) into its row: grey-line folder part and
    /// click target. Rows whose programs already run in a worktree are left alone.
    public static func apply(_ rows: [SessionRow], worktrees: [String: String]) -> [SessionRow] {
        rows.map { r in
            guard needsLookup(r), let p = worktrees[r.id], let wt = Classifier.worktree(of: p) else { return r }
            var r = r
            r.folderName = wt.name
            r.folderPath = wt.path
            return r
        }
    }
}
