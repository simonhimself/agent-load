import Foundation

/// Finds and reads the transcripts of terminal harness sessions (Claude Code, Codex, Pi),
/// read-only and cheaply:
/// - files live under ~/.claude, ~/.codex and ~/.pi (not ~/Documents, so no privacy prompt);
/// - a new file is read only at its head and tail (128 KB each); after that only the bytes
///   appended since the last read; an unchanged file (same size) is not read at all;
/// - the head of a candidate file (64 KB, for its cwd / origin) is read once and kept.
/// Not thread-safe: use from the sampler's serial queue.
public final class TranscriptStore {
    let home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    private struct FileState { var size: UInt64; var offset: UInt64; var scan: TranscriptScan; var mtimeMs: Int64 }
    private var files: [String: FileState] = [:]
    private var heads: [String: String] = [:]
    /// Transcripts named explicitly by argv (`--resume <id>` …), resolved once per process.
    private var explicit: [ProcKey: String] = [:]
    private var codexIndex: (mtime: Date, map: [String: String])?

    static let headBytes = 128 * 1024
    static let tailBytes = 128 * 1024
    /// Slack between a process start and the creation of its transcript file.
    static let slackMs: Int64 = 10_000

    // MARK: Public

    /// Transcript info per harness root, for all live harness groups of this refresh.
    public func infos(for groups: [Classifier.HarnessGroup]) -> [ProcKey: TranscriptInfo] {
        let live = Set(groups.map(\.root.key))
        explicit = explicit.filter { live.contains($0.key) }
        var paths: [ProcKey: String] = [:]

        // 1. Transcripts named in argv.
        for g in groups {
            if let p = explicit[g.root.key] ?? explicitPath(g) {
                explicit[g.root.key] = p
                paths[g.root.key] = p
            }
        }
        // 2. The others: a file in the session's folder created after the process started.
        //    Each file goes to the latest-started process that is older than it, so two
        //    sessions in one folder never share a file.
        let claimed = Set(paths.values)
        var byFolder: [String: [Classifier.HarnessGroup]] = [:]
        for g in groups where paths[g.root.key] == nil {
            for dir in folders(for: g) { byFolder[dir, default: []].append(g) }
        }
        for (dir, gs) in byFolder {
            let oldest = gs.map { $0.root.startMicros / 1000 }.min() ?? 0
            let cands = candidates(in: dir, harness: gs[0].harness, cwds: Set(gs.map(\.cwd)), modifiedSince: oldest - Self.slackMs)
                .filter { !claimed.contains($0.path) }
            var owned: [ProcKey: (path: String, created: Int64)] = [:]
            for c in cands {
                let owners = gs.filter { $0.root.startMicros / 1000 <= c.created + Self.slackMs
                    && (gs[0].harness != .codex || c.cwd == nil || sameDir(c.cwd!, $0.cwd)) }
                guard let o = owners.max(by: { $0.root.startMicros < $1.root.startMicros }) else { continue }
                if owned[o.root.key].map({ $0.created < c.created }) ?? true { owned[o.root.key] = (c.path, c.created) }
            }
            let taken = Set(owned.values.map(\.path))
            for g in gs where paths[g.root.key] == nil {
                if let o = owned[g.root.key] { paths[g.root.key] = o.path; continue }
                // `--continue` / `resume --last`: continues an older file, written to since the start.
                if continues(g) {
                    let startMs = g.root.startMicros / 1000
                    if let c = cands.filter({ !taken.contains($0.path) && $0.modified >= startMs - Self.slackMs })
                        .max(by: { $0.modified < $1.modified }) { paths[g.root.key] = c.path }
                }
            }
        }

        var out: [ProcKey: TranscriptInfo] = [:]
        for g in groups {
            guard let p = paths[g.root.key], let st = read(p, harness: g.harness) else { continue }
            var title = st.scan.title
            if g.harness == .codex, let id = st.scan.sessionID ?? Self.codexID(fromPath: p), let n = codexThreadName(id) {
                title = n
            }
            out[g.root.key] = TranscriptInfo(path: p, title: title, lastUserMs: st.scan.lastUserMs, modifiedMs: st.mtimeMs)
        }
        // Forget files no process uses any more (brain transcripts read since the last call count).
        let used = Set(out.values.map(\.path)).union(brainFiles)
        files = files.filter { used.contains($0.key) }
        brainFiles.removeAll()
        return out
    }

    /// Latest user message of a Claude Code brain (a `claude` run by opencode for a session on the
    /// claude-code provider): its transcript is `--resume <id>`'s file in the cwd's folder, else
    /// the newest file there created after the process started. Read incrementally like the others.
    public func brainLastUser(root: ProcInfo, cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let dir = claudeRoot + "/" + HarnessDetect.claudeFolderName(cwd: cwd)
        var path: String?
        if let id = HarnessDetect.argValue(root.argv, ["--resume", "-r", "--session-id"]), Self.isSafeName(id) {
            path = dir + "/" + id + ".jsonl"
        } else {
            let startMs = root.startMicros / 1000
            path = candidates(in: dir, harness: .pi, cwds: [], modifiedSince: startMs - Self.slackMs)   // .pi: no filtering
                .filter { $0.created >= startMs - Self.slackMs }.max { $0.created < $1.created }?.path
        }
        guard let p = path, let st = read(p, harness: .claudeCode) else { return nil }
        brainFiles.insert(p)
        return st.scan.lastUser
    }
    /// Transcripts read for brains this refresh (kept in the cache next to the harness ones).
    private var brainFiles = Set<String>()

    // MARK: Locating

    private var claudeRoot: String { home + "/.claude/projects" }
    private var codexRoot: String { home + "/.codex/sessions" }
    private var piRoot: String { home + "/.pi/agent/sessions" }

    /// Folders where a new transcript of this session appears.
    func folders(for g: Classifier.HarnessGroup) -> [String] {
        guard !g.cwd.isEmpty else { return [] }
        switch g.harness {
        case .claudeCode: return [claudeRoot + "/" + HarnessDetect.claudeFolderName(cwd: g.cwd)]
        case .pi: return [piRoot + "/" + HarnessDetect.piFolderName(cwd: g.cwd)]
        case .codex:
            // Rollouts are filed by the local date they were created on.
            let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
            let start = Date(timeIntervalSince1970: Double(g.root.startMicros) / 1e6)
            return Array(Set([f.string(from: start), f.string(from: Date())])).sorted().map { codexRoot + "/" + $0 }
        default: return []
        }
    }

    func continues(_ g: Classifier.HarnessGroup) -> Bool {
        switch g.harness {
        case .claudeCode, .pi: return g.root.argv.contains("-c") || g.root.argv.contains("--continue")
        case .codex: return g.root.argv.contains("resume") && g.root.argv.contains("--last")
        default: return false
        }
    }

    struct Candidate { var path: String; var created: Int64; var modified: Int64; var cwd: String? }

    /// Transcripts in `dir` written since `modifiedSince` (ms): older files cannot belong to a
    /// process that started later, and skipping them keeps big folders cheap.
    func candidates(in dir: String, harness: Harness, cwds: Set<String>, modifiedSince: Int64) -> [Candidate] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [Candidate] = []
        for n in names where n.hasSuffix(".jsonl") {
            let p = dir + "/" + n
            guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
            let created = Int64(((a[.creationDate] as? Date) ?? .distantPast).timeIntervalSince1970 * 1000)
            let modified = Int64(((a[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970 * 1000)
            guard modified >= modifiedSince else { continue }
            var cwd: String?
            switch harness {
            case .claudeCode:
                // Claude Code processes driven by opencode (Agent SDK, entrypoint "sdk-ts") write
                // into the same folders; their files are never a terminal session's.
                if head(p).contains("\"entrypoint\":\"sdk-ts\"") { continue }
            case .codex:
                // The first line (session_meta) names the session's folder.
                cwd = Self.jsonString(after: "\"cwd\":\"", in: head(p))
                if let c = cwd, !cwds.contains(where: { sameDir($0, c) }) { continue }
                if head(p).contains("\"originator\":\"Codex Desktop\"") { continue }
            default: break
            }
            out.append(Candidate(path: p, created: created, modified: modified, cwd: cwd))
        }
        return out
    }

    /// Transcript named in argv: Claude `--resume <id>` / `--session-id <id>`, Codex
    /// `resume <id>`, Pi `--session <file or id>` / `--session-id <id>`.
    func explicitPath(_ g: Classifier.HarnessGroup) -> String? {
        let fm = FileManager.default
        let argv = g.root.argv
        switch g.harness {
        case .claudeCode:
            guard let id = HarnessDetect.argValue(argv, ["--resume", "-r", "--session-id"]), Self.isSafeName(id) else { return nil }
            if argv.contains("--fork-session") { return nil }   // writes a new file
            let own = claudeRoot + "/" + HarnessDetect.claudeFolderName(cwd: g.cwd) + "/" + id + ".jsonl"
            if fm.fileExists(atPath: own) { return own }
            for d in (try? fm.contentsOfDirectory(atPath: claudeRoot)) ?? [] {
                let p = claudeRoot + "/" + d + "/" + id + ".jsonl"
                if fm.fileExists(atPath: p) { return p }
            }
            return nil
        case .codex:
            guard let i = argv.firstIndex(of: "resume"), i + 1 < argv.count else { return nil }
            let id = argv[i + 1]
            guard id.count >= 32, Self.isSafeName(id) else { return nil }
            let e = fm.enumerator(atPath: codexRoot)
            while let rel = e?.nextObject() as? String {
                if rel.hasSuffix(id + ".jsonl") { return codexRoot + "/" + rel }
            }
            return nil
        case .pi:
            guard let v = HarnessDetect.argValue(argv, ["--session", "--session-id"]) else { return nil }
            if v.hasSuffix(".jsonl") { return v.hasPrefix("/") ? v : g.cwd + "/" + v }
            guard Self.isSafeName(v) else { return nil }
            let own = piRoot + "/" + HarnessDetect.piFolderName(cwd: g.cwd)
            for d in [own] + ((try? fm.contentsOfDirectory(atPath: piRoot)) ?? []).map({ piRoot + "/" + $0 }) {
                if let n = ((try? fm.contentsOfDirectory(atPath: d)) ?? []).first(where: { $0.hasSuffix("_" + v + ".jsonl") }) {
                    return d + "/" + n
                }
            }
            return nil
        default: return nil
        }
    }

    // MARK: Reading

    /// First 64 KB of a file, read once (the start of a transcript never changes).
    func head(_ path: String) -> String {
        if let h = heads[path] { return h }
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let d = (try? fh.read(upToCount: 64 * 1024)) ?? Data()
        let s = String(decoding: d, as: UTF8.self)
        if heads.count > 2000 { heads.removeAll() }
        heads[path] = s
        return s
    }

    /// Scans new bytes of a transcript; returns the accumulated state.
    private func read(_ path: String, harness: Harness) -> FileState? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.uint64Value else { return nil }
        let mtimeMs = Int64(((a[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970 * 1000)
        if var st = files[path], size >= st.size {
            st.mtimeMs = mtimeMs
            if size == st.size { files[path] = st; return st }
            guard let fh = FileHandle(forReadingAtPath: path) else { return st }
            defer { try? fh.close() }
            var from = st.offset
            var dropFirst = false
            if size - from > 1 << 20 { from = size - UInt64(Self.tailBytes); dropFirst = true }   // jumped a lot: tail only
            let (text, consumed) = Self.completeLines(fh, from: from, to: size, dropFirstPartial: dropFirst)
            TranscriptParser.scan(text, harness: harness, into: &st.scan)
            st.offset = from + consumed
            st.size = size
            files[path] = st
            return st
        }
        // New (or rewritten) file: head and tail.
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var scan = TranscriptScan()
        var offset: UInt64
        if size <= UInt64(Self.headBytes + Self.tailBytes) {
            let (text, consumed) = Self.completeLines(fh, from: 0, to: size, dropFirstPartial: false)
            TranscriptParser.scan(text, harness: harness, into: &scan)
            offset = consumed
        } else {
            let (h, _) = Self.completeLines(fh, from: 0, to: UInt64(Self.headBytes), dropFirstPartial: false)
            TranscriptParser.scan(h, harness: harness, into: &scan)
            let from = size - UInt64(Self.tailBytes)
            let (t, consumed) = Self.completeLines(fh, from: from, to: size, dropFirstPartial: true)
            TranscriptParser.scan(t, harness: harness, into: &scan)
            offset = from + consumed
        }
        let st = FileState(size: size, offset: offset, scan: scan, mtimeMs: mtimeMs)
        files[path] = st
        return st
    }

    /// Bytes [from, to) cut to whole lines: without the partial line at the end (still being
    /// written; read next time) and, if asked, without the partial line at the start.
    /// Returns the text and how many bytes from `from` were consumed (up to the last newline).
    static func completeLines(_ fh: FileHandle, from: UInt64, to: UInt64, dropFirstPartial: Bool) -> (Substring, UInt64) {
        guard to > from, (try? fh.seek(toOffset: from)) != nil,
              let d = try? fh.read(upToCount: Int(to - from)), !d.isEmpty else { return ("", 0) }
        guard let lastNL = d.lastIndex(of: 0x0A) else { return ("", 0) }
        var start = d.startIndex
        if dropFirstPartial {
            guard let firstNL = d.firstIndex(of: 0x0A), firstNL < lastNL else { return ("", UInt64(lastNL - d.startIndex + 1)) }
            start = firstNL + 1
        }
        let s = String(decoding: d[start...lastNL], as: UTF8.self)
        return (Substring(s), UInt64(lastNL - d.startIndex + 1))
    }

    // MARK: Codex session index

    func codexThreadName(_ id: String) -> String? {
        let p = home + "/.codex/session_index.jsonl"
        guard let a = try? FileManager.default.attributesOfItem(atPath: p), let m = a[.modificationDate] as? Date,
              let size = (a[.size] as? NSNumber)?.uint64Value else { return nil }
        if codexIndex?.mtime != m, let fh = FileHandle(forReadingAtPath: p) {
            defer { try? fh.close() }
            let from = size > 256 * 1024 ? size - 256 * 1024 : 0
            let (t, _) = Self.completeLines(fh, from: from, to: size, dropFirstPartial: from > 0)
            codexIndex = (m, TranscriptParser.codexIndex(t))
        }
        return codexIndex?.map[id]
    }

    // MARK: Helpers

    /// `rollout-2026-06-14T20-10-42-019ec754-292a-7a70-8e39-7effc3cc0e6f.jsonl` → the uuid.
    static func codexID(fromPath p: String) -> String? {
        let n = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
        guard n.count >= 36 else { return nil }
        return String(n.suffix(36))
    }

    /// Ids used in file names: no path separators or dots.
    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && !s.contains("/") && !s.contains("..")
    }

    /// The JSON string value right after `prefix` (simple; enough for paths in session_meta).
    static func jsonString(after prefix: String, in text: String) -> String? {
        guard let r = text.range(of: prefix) else { return nil }
        var out = ""
        var esc = false
        for ch in text[r.upperBound...] {
            if esc { out.append(ch == "/" ? "/" : ch); esc = false; continue }
            if ch == "\\" { esc = true; continue }
            if ch == "\"" { return out }
            out.append(ch)
        }
        return nil
    }
}

/// `/tmp/x` and `/private/tmp/x` are the same folder (the kernel reports the latter).
func sameDir(_ a: String, _ b: String) -> Bool {
    func norm(_ s: String) -> String { s.hasPrefix("/private/") ? String(s.dropFirst("/private".count)) : s }
    return norm(a) == norm(b)
}
